{ module, packages }:
{ config, lib, pkgs, ... }:
{
  imports = [ module ];
  networking.hostId = lib.mkDefault "aabbccdd";
  virtualisation.memorySize = 2048;
  virtualisation.cores = 2;
  # @cc [owner:ghuntley,label:verification] roles-require-hardware-virtualization
  # A missing KVM capability MUST fail the test; QEMU MUST NOT fall back to TCG.
  virtualisation.qemu.forceAccel = lib.mkForce true;
  virtualisation.qemu.options = [ "-cpu host" ];
  system.stateVersion = "26.05";
  environment.systemPackages = [ pkgs.curl pkgs.jq ];
  systemd.services.overalls-test-fixture = {
    before = [ "postgresql.service" ];
    path = [ pkgs.openssl ];
    script = ''
      ${pkgs.python3}/bin/python ${./role-fixture.py}
      install -m 0600 ${../fixtures/ssh-host-ca/key} /run/overalls-test/ssh-host-ca
      ${lib.optionalString config.services.marshall.enable ''
        install -d -m 0700 -o postgres -g postgres /run/overalls-test-db
        install -m 0600 -o postgres -g postgres /run/overalls-test/tls.key /run/overalls-test-db/tls.key
        install -m 0600 -o postgres -g postgres /run/overalls-test/tls.crt /run/overalls-test-db/tls.crt
        install -m 0600 -o postgres -g postgres /run/overalls-test/database.sql /run/overalls-test-db/database.sql
      ''}
      ${lib.optionalString config.services.marshallProxy.enable ''
        install -d -m 0750 -o root -g haproxy /run/overalls-test-proxy
        cat /run/overalls-test/tls.key /run/overalls-test/tls.crt > /run/overalls-test-proxy/full.pem
        chgrp haproxy /run/overalls-test-proxy/full.pem
        chmod 0640 /run/overalls-test-proxy/full.pem
        install -m 0640 -o root -g haproxy /run/overalls-test/ca.crt /run/overalls-test-proxy/ca.crt
      ''}
    '';
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
  };
  services.marshall = lib.mkIf config.services.marshall.enable {
    publicHost = "control.example.test";
    ingress.zone = lib.mkDefault "apps.example.test";
    sshHostCa = {
      publicKey = lib.removeSuffix "\n" (builtins.readFile ../fixtures/ssh-host-ca/key.pub);
      keyFile = "/run/overalls-test/ssh-host-ca";
    };
    poolSize = 2;
    databaseConnectionBudget = 19;
    cpuCores = 1;
    memoryMiB = 1024;
    environmentFile = "/run/overalls-test/marshall.env";
    databaseCAFile = "/run/overalls-test/ca.crt";
    secretUnits = [ "overalls-test-fixture.service" ];
    instances.${config.networking.hostName} = {
      port = 4443;
      certificateFile = "/run/overalls-test/tls.crt";
      keyFile = "/run/overalls-test/tls.key";
    };
  };
  services.lilly = lib.mkIf config.services.lilly.enable {
    hostId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    controlPlane = "https://localhost:5443";
    controlPlaneCAFile = "/run/overalls-test/ca.crt";
    credentialFile = "/run/overalls-test/lilly.json";
    secretUnits = [ "overalls-test-fixture.service" ];
    egressInterface = "eth1";
    guestCpuCores = 1;
    guestMemoryMiB = 256;
    # Synthetic backing for service-role configuration only. Execution suites
    # install their own observed storage identity before exercising real guests.
    pools = lib.mkDefault [{
      id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
      path = "/pool";
      filesystem_id = "zfs:123:456";
      storage = { dataset = "tank/lilly"; dataset_guid = "456"; zpool_guid = "123"; };
    }];
  };
  services.marshallProxy = lib.mkIf config.services.marshallProxy.enable {
    publicHost = "control.example.test";
    bindAddress = "127.0.0.1";
    certificateFile = lib.mkDefault "/run/overalls-test-proxy/full.pem";
    backendCAFile = "/run/overalls-test-proxy/ca.crt";
    secretUnits = [ "overalls-test-fixture.service" ];
    backends.local = { address = "127.0.0.1"; port = 4443; serverName = "localhost"; };
  };
  services.postgresql = lib.mkIf config.services.marshall.enable {
    enable = true;
    package = pkgs.postgresql_18;
    enableTCPIP = true;
    ensureDatabases = [ "marshall" ];
    ensureUsers = [{ name = "marshall"; ensureDBOwnership = true; }];
    authentication = lib.mkForce ''
      local all all peer
      hostssl marshall marshall 127.0.0.1/32 scram-sha-256
      hostssl marshall marshall ::1/128 scram-sha-256
    '';
    settings = {
      ssl = true;
      ssl_cert_file = "/run/overalls-test-db/tls.crt";
      ssl_key_file = "/run/overalls-test-db/tls.key";
      log_statement = "none";
      log_min_error_statement = "panic";
    };
  };
  systemd.services.postgresql = lib.mkIf config.services.marshall.enable {
    after = [ "overalls-test-fixture.service" ];
    requires = [ "overalls-test-fixture.service" ];
  };
  systemd.services.postgresql-setup = lib.mkIf config.services.marshall.enable {
    postStart = lib.mkAfter ''
      ${config.services.postgresql.package}/bin/psql --no-psqlrc -v ON_ERROR_STOP=1 \
        -f /run/overalls-test-db/database.sql >/dev/null
    '';
  };

  # @cc [owner:ghuntley,label:verification] fixture-explicit-migration
  # The test driver MUST invoke this one-shot migration explicitly. Booting
  # a module MUST NOT create or migrate the application schema automatically.
  systemd.services.overalls-test-migrate = lib.mkIf config.services.marshall.enable {
    after = [ "postgresql-setup.service" ];
    requires = [ "postgresql-setup.service" ];
    environment = {
      PHX_SERVER = "false";
      PHX_HOST = "control.example.test";
      RELEASE_DISTRIBUTION = "none";
      RELEASE_COOKIE = "isolated-migration-test";
      MARSHALL_REPLICA_COUNT = "3";
      MARSHALL_DB_CONNECTION_BUDGET = "19";
      POOL_SIZE = "2";
      MARSHALL_DB_CA_CERTFILE = "/run/overalls-test/ca.crt";
      ERL_CRASH_DUMP = "/dev/null";
    };
    script = ''
      exec ${pkgs.coreutils}/bin/env -u PORT MARSHALL_INSTANCE_ID=migration-test \
        MARSHALL_DB_TLS=verify \
        ${packages.marshall}/bin/marshall eval 'Marshall.Operations.Migrate.main()'
    '';
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = "/run/overalls-test/marshall.env";
    };
  };
}

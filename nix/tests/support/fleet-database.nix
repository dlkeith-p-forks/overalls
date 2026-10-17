# Shared only by the fleet and credential-rotation fixtures. The caller retains
# the connection budget and service identity used by its recovery assertions.
{ generationService, maxConnections, allowedNetwork }:
{ config, lib, pkgs, ... }:
let
  root = "/var/lib/overalls-fleet";
  database = "/var/lib/overalls-fleet-db";
in
{
  systemd.services.${generationService} = {
    before = [ "postgresql.service" ];
    path = [ pkgs.openssl ];
    script = ''
      ${pkgs.python3}/bin/python ${./fleet-credentials.py}
      install -d -m 0700 -o postgres -g postgres ${database}
      install -m 0600 -o postgres -g postgres ${root}/db/tls.key ${database}/tls.key
      install -m 0600 -o postgres -g postgres ${root}/db/tls.crt ${database}/tls.crt
      install -m 0600 -o postgres -g postgres ${root}/database.sql ${database}/database.sql
    '';
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
  };
  services.postgresql = {
    enable = true;
    # Match Marshall.Repo.min_pg_version, including native UUIDv7 defaults.
    package = pkgs.postgresql_18;
    enableTCPIP = true;
    ensureDatabases = [ "marshall" ];
    ensureUsers = [{ name = "marshall"; ensureDBOwnership = true; }];
    authentication = lib.mkForce ''
      local all all peer
      hostssl marshall marshall ${allowedNetwork} scram-sha-256
    '';
    settings = {
      ssl = true;
      ssl_cert_file = "${database}/tls.crt";
      ssl_key_file = "${database}/tls.key";
      max_connections = maxConnections;
      log_statement = "none";
      log_min_error_statement = "panic";
    };
  };
  networking.firewall.allowedTCPPorts = [ 5432 ];
  systemd.services.postgresql = {
    after = [ "${generationService}.service" ];
    requires = [ "${generationService}.service" ];
  };
  systemd.services.postgresql-setup.postStart = lib.mkAfter ''
    ${config.services.postgresql.package}/bin/psql --no-psqlrc -v ON_ERROR_STOP=1 \
      -d marshall -f ${database}/database.sql >/dev/null
  '';
}

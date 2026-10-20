{ config, lib, pkgs, ... }:
let
  marshall = config.services.marshall;
  mailEnvironment = import ../../../nix/domains/system/smtp-relay/environment.nix {
    inherit lib;
    cfg = marshall.smtpRelay;
  };
  registration = pkgs.writeText "overalls-configure-porsche.exs" ''
    Application.put_env(:marshall, :operator_mode, true)
    with {:ok, _} <- Application.ensure_all_started(:marshall),
         {:ok, _} <- Marshall.Operations.SSHGateway.configure(
           "overalls", "/run/overalls-porsche-authority/gateway.token") do
      IO.puts("Porsche gateway authority configured")
    else
      _ ->
        IO.puts(:stderr, "Porsche gateway authority configuration failed")
        System.halt(1)
    end
  '';
in
{
  # @cc [owner:ghuntley,label:security;recovery] overalls-porsche-bootstrap
  # Gateway bootstrap MUST use the trusted Ash operator action and private
  # systemd credentials. Reapplying the same token MUST preserve generation;
  # errors MUST fail startup without exposing token or database credentials.
  systemd.services.overalls-porsche-authority = lib.mkIf (!config.overalls.controlPlaneHost.bootstrap) {
    description = "Configure Porsche gateway authority in Marshall";
    wantedBy = [ "multi-user.target" ];
    after = [ "overalls-database-password.service" "overalls-secrets-marshall.service" "overalls-secrets-porsche.service" ];
    requires = [ "overalls-database-password.service" "overalls-secrets-marshall.service" "overalls-secrets-porsche.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "marshall-operator";
      Group = "marshall-operator";
      UMask = "0077";
      EnvironmentFile = marshall.environmentFile;
      LoadCredential = [ "database-ca.crt:${marshall.databaseCAFile}" "gateway.token:/run/overalls-secrets/porsche/token" ];
      RuntimeDirectory = "overalls-porsche-authority";
      RuntimeDirectoryMode = "0700";
      TimeoutStartSec = 120;
      NoNewPrivileges = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
    script = ''
      ${pkgs.coreutils}/bin/install -m 0600 "$CREDENTIALS_DIRECTORY/gateway.token" /run/overalls-porsche-authority/gateway.token
      export RELEASE_COOKIE
      RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
      exec ${pkgs.coreutils}/bin/env -u PORT ${mailEnvironment} \
        PHX_SERVER=false RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP=/dev/null \
        RELEASE_TMP=/run/overalls-porsche-authority \
        PHX_HOST=${lib.escapeShellArg marshall.publicHost} \
        MARSHALL_INSTANCE_ID=porsche-authority \
        MARSHALL_REPLICA_COUNT=${toString marshall.replicaCount} \
        POOL_SIZE=${toString marshall.poolSize} \
        MARSHALL_DB_CONNECTION_BUDGET=${toString marshall.databaseConnectionBudget} \
        MARSHALL_DB_TLS=verify MARSHALL_DB_CA_CERTFILE="$CREDENTIALS_DIRECTORY/database-ca.crt" \
        ${marshall.package}/bin/marshall eval 'Code.eval_file("${registration}")'
    '';
  };
}

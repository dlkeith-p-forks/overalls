{ config, lib, pkgs, ... }:
let
  cfg = config.services.marshall;
  mailEnvironment = import ./smtp-relay/environment.nix { inherit lib; cfg = cfg.smtpRelay; };
  launch = pkgs.writeShellScript "marshall-enrollment-release" ''
    set -eu
    export RELEASE_COOKIE
    RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
    export RELEASE_TMP="$(dirname "$3")"
    exec ${pkgs.coreutils}/bin/env -u PORT ${mailEnvironment} \
      PHX_SERVER=false RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP=/dev/null \
      PHX_HOST=${lib.escapeShellArg cfg.publicHost} \
      MARSHALL_INSTANCE_ID=enrollment-operator \
      MARSHALL_REPLICA_COUNT=${toString cfg.replicaCount} \
      POOL_SIZE=${toString cfg.poolSize} \
      MARSHALL_DB_CONNECTION_BUDGET=${toString cfg.databaseConnectionBudget} \
      MARSHALL_DB_TLS=verify MARSHALL_DB_CA_CERTFILE="$CREDENTIALS_DIRECTORY/database-ca.crt" \
      ${cfg.package}/bin/marshall eval 'Marshall.Operations.CLI.main()' "$@"
  '';
  bridge = pkgs.writeShellApplication {
    name = "overalls-marshall-enrollment";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      exec ${pkgs.python3}/bin/python ${../artifacts/host/marshall_operator.py} ${lib.escapeShellArg cfg.environmentFile} ${launch} ${lib.escapeShellArg cfg.databaseCAFile}
    '';
  };
in {
  config = lib.mkIf cfg.enable {
    users.groups.marshall-operator = {};
    users.users.marshall-operator = { isSystemUser = true; group = "marshall-operator"; };
    environment.systemPackages = [ bridge ];
  };
}

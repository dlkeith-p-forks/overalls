{ packages }:
{ config, lib, ... }:
let cfg = config.services.peach; lilly = config.services.lilly; paths = import ./types.nix { inherit lib; };
    runtime = builtins.toFile "peach-config.json" (builtins.toJSON { socket = cfg.socket; host_id = cfg.hostId; control_plane = cfg.controlPlane; credential_file = cfg.credentialFile; ca_file = cfg.caFile; });
in {
  options.services.peach = {
    enable = lib.mkEnableOption "guest reflection service";
    package = lib.mkOption { type = lib.types.package; default = packages.peach; };
    hostId = lib.mkOption { type = paths.uuid; default = lilly.hostId; };
    controlPlane = lib.mkOption { type = lib.types.str; default = lilly.controlPlane; };
    caFile = lib.mkOption { type = paths.absolutePath; default = lilly.controlPlaneCAFile; };
    secretsFile = lib.mkOption { type = paths.absolutePath; };
    credentialFile = lib.mkOption { type = paths.privatePath; default = "/run/overalls-secrets/peach/control.token"; readOnly = true; };
    socket = lib.mkOption { type = paths.privatePath; default = "/run/peach/reflection.sock"; };
    secretUnits = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
  };
  config = lib.mkIf cfg.enable {
    assertions = [{ assertion = lilly.enable; message = "Peach requires Lilly."; }];
    services.overallsSecrets.enable = true;
    services.overallsSecrets.bundles.peach = { encryptedFile = cfg.secretsFile; outputs = { "control.token" = { format = "raw"; secrets = [ "PEACH_CREDENTIAL" ]; }; }; };
    users.groups.peach = {};
    users.users.peach = { isSystemUser = true; group = "peach"; };
    systemd.services.peach = {
      wantedBy = [ "multi-user.target" ]; after = [ "lilly.service" ] ++ cfg.secretUnits; requires = [ "lilly.service" ] ++ cfg.secretUnits;
      environment = { PEACH_CONFIG_FILE = runtime; RELEASE_DISTRIBUTION = "none"; RELEASE_TMP = "/run/peach"; ERL_CRASH_DUMP = "/dev/null"; };
      serviceConfig = { Type = "exec"; User = "peach"; Group = "peach"; RuntimeDirectory = "peach"; RuntimeDirectoryMode = "0750"; LoadCredential = [ "control.token:${cfg.credentialFile}" "ca.pem:${cfg.caFile}" ]; Restart = "on-failure"; NoNewPrivileges = true; PrivateTmp = true; ProtectSystem = "strict"; ProtectHome = true; RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ]; };
      script = "exec ${cfg.package}/bin/peach start";
    };
  };
}

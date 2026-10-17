{ config, lib, pkgs, ... }:
let cfg = config.services.overallsCrashDumpRetention;
in {
  options.services.overallsCrashDumpRetention.directories = lib.mkOption {
    type = lib.types.listOf lib.types.str; default = [];
    internal = true;
  };
  config = lib.mkIf (cfg.directories != []) {
    systemd.services.overalls-crash-dump-retention = {
      script = lib.concatMapStringsSep "\n" (directory:
        "${pkgs.python3}/bin/python ${./runtime.py} prune ${lib.escapeShellArg directory}") cfg.directories;
      serviceConfig = { Type = "oneshot"; User = "root"; UMask = "0077"; NoNewPrivileges = true; };
    };
    systemd.timers.overalls-crash-dump-retention = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "5min"; OnUnitActiveSec = "1h"; };
    };
  };
}

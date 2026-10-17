{ config, lib, pkgs, ... }:
let cfg = config.services.lilly.firecrackerLogging;
in {
  options.services.lilly.firecrackerLogging = {
    enable = lib.mkOption { type = lib.types.bool; default = config.services.lilly.enable && (config.services.overallsLogging.enable or false); description = "Independent bounded native Firecracker diagnostics."; };
    maxBytes = lib.mkOption { type = lib.types.ints.positive; default = 1073741824; description = "Host-wide native log file budget."; };
    maxStreams = lib.mkOption { type = lib.types.ints.between 2 65536; default = 2048; };
  };
  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      # Lilly writes stream records here as `lilly` (ADR-0182).
      "d /var/lib/overalls-firecracker 0700 lilly lilly -"
      "d /var/log/overalls 0700 root root -"
      "d /var/log/overalls/firecracker 0700 root root -"
    ];
    systemd.services.overalls-firecracker-logging = {
      description = "Independent native Firecracker FIFO collector";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python ${./collector.py} ${toString cfg.maxBytes} ${toString cfg.maxStreams} ${toString config.users.users.lilly.uid}";
        Restart = "always"; RestartSec = 5; UMask = "0077";
        User = "root"; MemoryMax = "128M"; CPUQuota = "25%";
        CPUWeight = 5; IOWeight = 5; TasksMax = 16;
        LimitNOFILE = cfg.maxStreams + 64;
        NoNewPrivileges = true; CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ]; ProtectSystem = "strict"; ProtectHome = true;
        PrivateTmp = true; PrivateDevices = true;
        ReadWritePaths = [ "/var/lib/overalls-firecracker" "/var/log/overalls/firecracker" ];
        RestrictAddressFamilies = [ "AF_UNIX" ];
      };
    };
  };
}

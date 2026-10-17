{ config, lib, pkgs, ... }:
let
  cfg = config.overalls.terminald;
in
{
  options.overalls.terminald = {
    package = lib.mkOption {
      type = lib.types.package;
      description = "Static terminald multiplexer package.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 1075;
      description = "AF_VSOCK port the guest terminal multiplexer listens on.";
    };
    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "512M";
      description = "Memory ceiling for the terminal multiplexer and its scrollback rings.";
    };
  };

  # @cc [owner:ghuntley,label:recovery] guest-terminal-service-boundary
  # terminald MUST start only with the boot identity parameters, after guest
  # readiness, with bounded memory and
  # restart-on-failure. It MUST run as root: unprivileged session users are
  # resolved through passwd and applied per session before exec.
  # Service restrictions MUST NOT remove networking, kernel-tuning or device
  # access from its child login shells. The guest VM and host network policy
  # supply isolation; terminald itself accepts only authenticated host vsock.
  config.systemd.services.lilly-terminals = {
    description = "Lilly guest terminal multiplexer";
    wantedBy = [ "multi-user.target" ];
    wants = [ "lilly-readiness.service" ];
    after = [ "lilly-readiness.service" ];
    unitConfig.ConditionKernelCommandLine = [
      "lilly.placement" "lilly.execution_epoch" "lilly.boot_challenge" "lilly.ipv4"
    ];
    environment.LILLY_TERMINALD_PORT = toString cfg.port;
    serviceConfig = {
      Type = "simple";
      ExecStart = "${cfg.package}/bin/lilly-terminald";
      Restart = "on-failure";
      RestartSec = 2;
      ProtectHome = false;
      TasksMax = 512;
      MemoryMax = cfg.memoryMax;
      StandardOutput = "journal";
    };
  };
}

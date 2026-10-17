{ config, lib, ... }:
{
  options.overalls.sysctl.enable = lib.mkEnableOption "Overalls host BBR and fq profile";

  # @cc [owner:ghuntley,label:deployment] sysctl-explicit-opt-in
  # This profile MUST contribute no sysctls or kernel modules unless explicitly
  # enabled. Service roles MUST NOT implicitly enable it.
  config = lib.mkIf config.overalls.sysctl.enable {
    boot.kernelModules = [ "tcp_bbr" "sch_fq" ];

    # @cc [owner:ghuntley,label:deployment] sysctl-operator-overrides
    # Ordinary boot.kernel.sysctl assignments MUST override these defaults.
    # The profile MUST leave resource limits and forwarding policy inherited.
    boot.kernel.sysctl = {
      "net.ipv4.tcp_congestion_control" = lib.mkDefault "bbr";
      "net.core.default_qdisc" = lib.mkDefault "fq";
    };
  };
}

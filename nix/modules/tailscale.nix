{ config, lib, ... }:
let
  cfg = config.overalls.tailscale;
in
{
  options.overalls.tailscale.exitNode = lib.mkEnableOption "Tailscale exit-node advertisement and forwarding";

  config = lib.mkIf cfg.exitNode {
    # @cc [owner:ghuntley,label:security] tailscale-exit-node-routing
    # Enabling exit-node mode MUST advertise the node through Tailscale and
    # enable the kernel forwarding required to route tailnet traffic.
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "server";
      extraSetFlags = [ "--advertise-exit-node" ];
    };
  };
}

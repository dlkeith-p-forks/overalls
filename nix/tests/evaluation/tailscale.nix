{ pkgs, nixpkgs, module, fixtures }:
let
  inherit (pkgs) lib;
  system = "x86_64-linux";
  evaluate = extra: (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ module {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
    } extra ];
  }).config;
  bare = evaluate {};
  exitNode = evaluate { overalls.tailscale.exitNode = true; };

  # @cc [owner:ghuntley,label:verification] tailscale-configuration-check
  # These checks MUST exercise the production fleet profile on every host
  # fixture and confirm the daemon stays opt-in for service-only module
  # imports, without substituting service packages.
  cases = {
    optIn = !(bare.services.tailscale.enable) && !(bare.systemd.services ? tailscaled);
    exitNodeOptIn = !bare.overalls.tailscale.exitNode
      && exitNode.services.tailscale.enable
      && exitNode.services.tailscale.useRoutingFeatures == "server"
      && exitNode.boot.kernel.sysctl."net.ipv4.conf.all.forwarding"
      && exitNode.boot.kernel.sysctl."net.ipv6.conf.all.forwarding"
      && lib.hasInfix "set --advertise-exit-node" exitNode.systemd.services.tailscaled-set.script;
    fleetDefault = lib.all (name:
      let cfg = fixtures.${name}.config; in
      cfg.services.tailscale.enable
      && cfg.systemd.services ? tailscaled
      && cfg.systemd.network.networks ? "50-tailscale"
      && builtins.elem "tailscale0" cfg.networking.firewall.trustedInterfaces
      && lib.all (a: a.assertion) cfg.assertions)
      (builtins.attrNames fixtures);
  };
  failed = lib.attrNames (lib.filterAttrs (_: result: !result) cases);
in
assert lib.assertMsg (failed == []) "Tailscale configuration checks failed: ${lib.concatStringsSep ", " failed}";
pkgs.writeText "overalls-tailscale-configuration-check.json" (builtins.toJSON cases)

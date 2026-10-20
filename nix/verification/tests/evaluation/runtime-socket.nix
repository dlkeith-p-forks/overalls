{ pkgs, nixpkgs, module }:
let
  inherit (pkgs) lib;
  evaluate = settings: (nixpkgs.lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [ module {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
    } settings ];
  }).config;
  relay = extra: lib.recursiveUpdate {
    systemd.sockets.relay.socketConfig.FreeBind = true;
    overalls.runtimeSockets.relay = {
      addressFile = "/run/overalls-public-address/ipv4";
      addressUnit = "overalls-public-address.service";
      port = 5443;
    };
  } extra;
  valid = cfg: lib.all (item: item.assertion) cfg.assertions;
  rejected = settings:
    let cfg = evaluate settings;
        result = builtins.tryEval (valid cfg && builtins.deepSeq
          (lib.mapAttrs (name: _: cfg.systemd.services."overalls-runtime-socket-${name}".serviceConfig.ExecStart)
            cfg.overalls.runtimeSockets) true);
    in !result.success || !result.value;
  cases = {
    # @cc [owner:ghuntley,label:verification;security] runtime-socket-wiring
    # The applying unit MUST follow the address unit, keep the declared socket
    # options, and leave boot unable to start the socket without its drop-in.
    wired = let cfg = evaluate (relay {}); service = cfg.systemd.services.overalls-runtime-socket-relay; in
      valid cfg
        && cfg.systemd.sockets.relay.wantedBy == []
        && cfg.systemd.sockets.relay.listenStreams == []
        && cfg.systemd.sockets.relay.socketConfig.FreeBind
        && service.requires == [ "overalls-public-address.service" ]
        && service.after == [ "overalls-public-address.service" ]
        && builtins.elem "multi-user.target" service.wantedBy
        && service.serviceConfig.Type == "oneshot"
        && service.serviceConfig.RemainAfterExit
        && lib.hasInfix "--address-file /run/overalls-public-address/ipv4 --port 5443" service.serviceConfig.ExecStart
        && lib.hasInfix "--remove --socket relay" service.serviceConfig.ExecStopPost;
    defaultOff = let cfg = evaluate {}; in
      cfg.overalls.runtimeSockets == {} && !(cfg.systemd.services ? overalls-runtime-socket-relay);
    undeclaredRejected = rejected { overalls.runtimeSockets.relay = {
      addressFile = "/run/overalls-public-address/ipv4";
      addressUnit = "overalls-public-address.service";
      port = 5443;
    }; };
    staticStreamRejected = rejected (relay { systemd.sockets.relay.listenStreams = [ "192.0.2.10:5443" ]; });
    bootStartRejected = rejected (relay { systemd.sockets.relay.wantedBy = [ "sockets.target" ]; });
    storeFileRejected = rejected (relay { overalls.runtimeSockets.relay.addressFile = "/nix/store/address"; });
    unitTypeRejected = rejected (relay { overalls.runtimeSockets.relay.addressUnit = "address.target"; });
  };
in assert lib.assertMsg (lib.all (value: value) (builtins.attrValues cases)) (builtins.toJSON cases);
pkgs.writeText "overalls-runtime-socket-configuration.json" (builtins.toJSON cases)

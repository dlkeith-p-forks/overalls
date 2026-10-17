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
  nft = evaluate {
    networking.nftables.enable = true;
    overalls.fleetFirewall.enable = true;
  };
  iptables = evaluate {
    networking.nftables.enable = false;
    overalls.fleetFirewall.enable = true;
  };
  fleetNetwork = {
    overalls.fleetNetwork = {
      enable = true;
      address = "10.90.0.1";
      endpointAddress = "192.0.2.1";
      privateKeyFile = "/run/fleet/private-key";
      tcpPorts = [ 5443 ];
      peers.worker = {
        address = "10.90.0.2";
        endpointAddress = "192.0.2.2";
        publicKey = lib.concatStrings (lib.replicate 43 "A") + "=";
      };
    };
  };
  composedNft = evaluate {
    imports = [ ../../../domains/system/fleet-network.nix fleetNetwork ];
    networking.nftables.enable = true;
    overalls.fleetFirewall.enable = true;
    networking.firewall.extraInputRules = "tcp dport 9999 accept";
  };
  composedIptables = evaluate {
    imports = [ ../../../domains/system/fleet-network.nix fleetNetwork ];
    networking.nftables.enable = false;
    overalls.fleetFirewall.enable = true;
    networking.firewall.extraCommands = "iptables -w -A nixos-fw -p tcp --dport 9999 -j nixos-fw-accept";
  };
  standaloneNft = evaluate {
    imports = [ ../../../domains/system/fleet-network.nix fleetNetwork ];
    networking.nftables.enable = true;
    networking.firewall.extraInputRules = "tcp dport 9999 accept";
  };
  standaloneIptables = evaluate {
    imports = [ ../../../domains/system/fleet-network.nix fleetNetwork ];
    networking.nftables.enable = false;
    networking.firewall.extraCommands = "iptables -w -A nixos-fw -p tcp --dport 9999 -j nixos-fw-accept";
  };
  disabled = evaluate {};
  valid = cfg: lib.all (item: item.assertion) cfg.assertions;
  rejected = allowedHosts:
    let result = builtins.tryEval (let cfg = evaluate {
      overalls.fleetFirewall = { enable = true; inherit allowedHosts; };
    }; in builtins.deepSeq cfg.overalls.fleetFirewall.allowedHosts (valid cfg));
    in !result.success || !result.value;
  publicService = {
    overalls.fleetFirewall = {
      enable = true;
      publicServices.audi = {
        address = "192.0.2.10";
        tcpPorts = [ 22 53 443 ];
        udpPorts = [ 53 ];
        comment = "Audi public plane";
      };
    };
  };
  publicNft = evaluate (publicService // { networking.nftables.enable = true; });
  publicIptables = evaluate (publicService // { networking.nftables.enable = false; });
  rejectedPublic = publicServices:
    let result = builtins.tryEval (let cfg = evaluate {
      networking.nftables.enable = true;
      overalls.fleetFirewall = { enable = true; inherit publicServices; };
    }; in builtins.deepSeq cfg.overalls.fleetFirewall.publicServices (valid cfg));
    in !result.success || !result.value;

  # @cc [owner:ghuntley,label:verification] fleet-firewall-configuration-check
  # These checks MUST exercise both NixOS firewall backends, typed registry
  # failures and the disabled standalone module without substituting rules.
  cases = {
    optIn = !disabled.overalls.fleetFirewall.enable
      && !(builtins.elem "tailscale0" disabled.networking.firewall.trustedInterfaces);
    defaults = nft.overalls.fleetFirewall.allowedHosts == import ../../../policy/network/allowed-hosts.nix;
    tailscaleTrusted = nft.networking.firewall.enable
      && lib.sort builtins.lessThan nft.networking.firewall.trustedInterfaces == [ "lo" "tailscale0" ];
    noPublicPorts = lib.all (ports: ports == []) [
      nft.networking.firewall.allowedTCPPorts
      nft.networking.firewall.allowedUDPPorts
      nft.networking.firewall.allowedTCPPortRanges
      nft.networking.firewall.allowedUDPPortRanges
      iptables.networking.firewall.allowedTCPPorts
      iptables.networking.firewall.allowedUDPPorts
      iptables.networking.firewall.allowedTCPPortRanges
      iptables.networking.firewall.allowedUDPPortRanges
    ];
    nftRules = lib.all (fragment: lib.hasInfix fragment nft.networking.firewall.extraInputRules) [
      ''ip saddr 136.243.69.55 meta l4proto { tcp, udp } accept comment "Overalls fleet host"''
      ''ip saddr 136.243.69.35 meta l4proto { tcp, udp } accept comment "Dungarees fleet host"''
      ''ip saddr 103.134.170.11 meta l4proto { tcp, udp } accept comment "Geoffrey Huntley"''
      ''ip saddr 98.128.180.170 meta l4proto { tcp, udp } accept comment "Oskar"''
      ''ip saddr 23.16.102.97 meta l4proto { tcp, udp } accept comment "Carl Sverre"''
      ''ip saddr 202.73.33.218 meta l4proto { tcp, udp } accept comment "Singapore Office"''
      ''ip saddr 208.185.151.161 meta l4proto { tcp, udp } accept comment "Vienna Office"''
    ] && !(lib.hasInfix "dport" nft.networking.firewall.extraInputRules);
    iptablesRules = lib.all (fragment: lib.hasInfix fragment iptables.networking.firewall.extraCommands) [
      "-s 136.243.69.55 -p tcp"
      "-s 136.243.69.55 -p udp"
      "-s 136.243.69.35 -p tcp"
      "-s 136.243.69.35 -p udp"
      "-s 103.134.170.11 -p tcp"
      "-s 103.134.170.11 -p udp"
      "--comment 'Geoffrey Huntley'"
      "-s 98.128.180.170 -p tcp"
      "-s 98.128.180.170 -p udp"
      "--comment Oskar"
      "-s 23.16.102.97 -p tcp"
      "-s 23.16.102.97 -p udp"
      "--comment 'Carl Sverre'"
      "-s 202.73.33.218 -p tcp"
      "-s 202.73.33.218 -p udp"
      "--comment 'Singapore Office'"
      "-s 208.185.151.161 -p tcp"
      "-s 208.185.151.161 -p udp"
      "--comment 'Vienna Office'"
    ] && !(lib.hasInfix "--dport" iptables.networking.firewall.extraCommands);
    composedRules = valid composedNft && valid composedIptables
      && lib.all (fragment: lib.hasInfix fragment composedNft.networking.firewall.extraInputRules) [
      ''ip saddr 136.243.69.35 meta l4proto { tcp, udp } accept comment "Dungarees fleet host"''
      ''iifname "fleet0" ip saddr 10.90.0.2 ip daddr 10.90.0.1 tcp dport 5443 accept''
    ] && lib.all (fragment: lib.hasInfix fragment composedIptables.networking.firewall.extraCommands) [
      "-s 136.243.69.35 -p tcp"
      "-i fleet0 -s 10.90.0.2 -d 10.90.0.1 -p tcp --dport 5443"
    ]
      && !(lib.hasInfix "dport 9999" composedNft.networking.firewall.extraInputRules)
      && !(lib.hasInfix "--dport 9999" composedIptables.networking.firewall.extraCommands);
    standaloneComposition = valid standaloneNft && valid standaloneIptables
      && lib.hasInfix "dport 5443" standaloneNft.networking.firewall.extraInputRules
      && lib.hasInfix "dport 9999" standaloneNft.networking.firewall.extraInputRules
      && lib.hasInfix "--dport 5443" standaloneIptables.networking.firewall.extraCommands
      && lib.hasInfix "--dport 9999" standaloneIptables.networking.firewall.extraCommands;
    malformedAddress = rejected {
      invalid = { address = "999.1.1.1"; comment = "Invalid octet"; };
    };
    duplicateAddress = rejected {
      one = { address = "192.0.2.1"; comment = "First"; };
      two = { address = "192.0.2.1"; comment = "Second"; };
    };
    missingComment = rejected { invalid.address = "192.0.2.1"; };
    publicServiceRules = valid publicNft && valid publicIptables
      && lib.all (fragment: lib.hasInfix fragment publicNft.networking.firewall.extraInputRules) [
      ''ip daddr 192.0.2.10 tcp dport 443 accept comment "Audi public plane"''
      ''ip daddr 192.0.2.10 tcp dport 53 accept comment "Audi public plane"''
      ''ip daddr 192.0.2.10 udp dport 53 accept comment "Audi public plane"''
    ] && lib.all (fragment: lib.hasInfix fragment publicIptables.networking.firewall.extraCommands) [
      "-d 192.0.2.10 -p tcp --dport 443"
      "-d 192.0.2.10 -p udp --dport 53"
      "--comment 'Audi public plane'"
    ];
    publicServiceNoWildcard = rejectedPublic {
      wildcard = { address = "0.0.0.0"; tcpPorts = [ 443 ]; comment = "Wildcard"; };
    };
    publicServiceDuplicateAddress = rejectedPublic {
      one = { address = "192.0.2.10"; tcpPorts = [ 443 ]; comment = "First"; };
      two = { address = "192.0.2.10"; udpPorts = [ 53 ]; comment = "Second"; };
    };
    publicServiceNoPorts = rejectedPublic {
      empty = { address = "192.0.2.10"; comment = "No ports"; };
    };
    publicServiceDuplicatePorts = rejectedPublic {
      duplicate = { address = "192.0.2.10"; tcpPorts = [ 443 443 ]; comment = "Duplicate"; };
    };
  };
  failed = lib.attrNames (lib.filterAttrs (_: result: !result) cases);
in
assert lib.assertMsg (failed == []) "Fleet firewall checks failed: ${lib.concatStringsSep ", " failed}";
pkgs.writeText "overalls-fleet-firewall-check.json" (builtins.toJSON cases)

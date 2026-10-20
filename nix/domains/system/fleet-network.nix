{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.overalls.fleetNetwork;
  paths = import ./types.nix { inherit lib; };
  addressType = types.addCheck paths.ipv4 (address:
    lib.hasPrefix "10.90.0." address && !(builtins.elem address [ "10.90.0.0" "10.90.0.255" ]));
  peers = builtins.attrValues cfg.peers;
  addresses = map (peer: peer.address) peers;
  keys = map (peer: peer.publicKey) peers;
  perimeter = lib.attrByPath [ "overalls" "fleetFirewall" "enable" ] false config;
  perimeterPriority = if perimeter then lib.mkForce else value: value;
  runtimeFile = types.nullOr (types.strMatching "/run/[A-Za-z0-9_./-]+");
  unitName = types.strMatching "[a-zA-Z0-9_.@-]+\\.service";
  localRuntime = cfg.endpointAddressFile != null;
  runtimePeer = peer: peer.endpointAddressFile != null;
  handshakeRuntime = peer: localRuntime || runtimePeer peer;
  rules = lib.concatMap (peer:
    lib.optional (!handshakeRuntime peer)
      { source = peer.endpointAddress; destination = cfg.endpointAddress; protocol = "udp"; port = cfg.port; interface = null; }
    ++ map (port: { source = peer.address; destination = cfg.address; protocol = "tcp"; inherit port; interface = "fleet0"; }) cfg.tcpPorts
  ) peers;
  runtimePeers = lib.filterAttrs (_: runtimePeer) cfg.peers;
  peerUnit = name: "wireguard-fleet0-peer-${name}.service";
in {
  imports = [ ./runtime-firewall.nix ];
  options.overalls.fleetNetwork = {
    enable = lib.mkEnableOption "IPv4-only host fleet WireGuard transport";
    address = mkOption { type = addressType; description = "Unique host address in the dedicated 10.90.0.0/24 fleet network."; };
    endpointAddress = mkOption { type = types.nullOr paths.ipv4; default = null; description = "Physical IPv4 destination admitted for WireGuard handshakes."; };
    endpointAddressFile = mkOption { type = runtimeFile; default = null; description = "Runtime file holding the physical IPv4 destination, kept out of the repository."; };
    endpointUnits = mkOption { type = types.listOf unitName; default = []; description = "Units that publish the runtime endpoint files of this host and its peers."; };
    port = mkOption { type = types.port; default = 51820; };
    privateKeyFile = mkOption { type = paths.privatePath; description = "Runtime private WireGuard key; never embedded in the store."; };
    secretUnits = mkOption { type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service"); default = []; };
    tcpPorts = mkOption { type = types.listOf types.port; default = []; description = "Local fleet services admitted only from configured tunnel peers."; };
    peers = mkOption {
      default = {};
      type = types.attrsOf (types.submodule {
        options = {
          address = mkOption { type = addressType; };
          endpointAddress = mkOption { type = types.nullOr paths.ipv4; default = null; };
          endpointAddressFile = mkOption { type = runtimeFile; default = null; description = "Runtime file holding the peer's physical IPv4 endpoint."; };
          port = mkOption { type = types.port; default = 51820; };
          publicKey = mkOption { type = types.strMatching "[A-Za-z0-9+/]{43}="; };
        };
      });
    };
  };

  # @cc [owner:ghuntley,label:security] fleet-tunnel-host-only-ipv4
  # Fleet transport MUST route only explicitly keyed peer /32 IPv4 addresses.
  # It MUST NOT route guest subnets, forward packets between interfaces, enable
  # IPv6, trust the tunnel interface globally or expose fleet TCP ports outside
  # that interface. Missing private key custody MUST fail tunnel startup.
  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = peers != []; message = "Fleet networking requires explicit keyed peers."; }
      { assertion = lib.unique addresses == addresses && !(builtins.elem cfg.address addresses);
        message = "Fleet IPv4 addresses must be unique and exclude the local host."; }
      { assertion = lib.unique keys == keys; message = "Fleet peers must have distinct public keys."; }
      { assertion = !config.networking.enableIPv6; message = "Fleet networking forbids IPv6."; }
      { assertion = config.networking.firewall.enable && !(builtins.elem "fleet0" config.networking.firewall.trustedInterfaces);
        message = "Fleet networking requires an active firewall and an untrusted tunnel interface."; }
      { assertion = !config.networking.wireguard.useNetworkd; message = "Fleet key preparation requires the WireGuard service backend."; }
      { assertion = cfg.endpointAddress != "0.0.0.0" && lib.all (peer: peer.endpointAddress != "0.0.0.0") peers;
        message = "Fleet endpoints must be explicit IPv4 addresses."; }
      { assertion = lib.all (endpoint: (endpoint.endpointAddress == null) != (endpoint.endpointAddressFile == null)) ([ cfg ] ++ peers);
        message = "Fleet endpoints need exactly one of endpointAddress or endpointAddressFile."; }
      { assertion = (!localRuntime && runtimePeers == {}) || cfg.endpointUnits != [];
        message = "Runtime fleet endpoints must name the units that publish them."; }
    ];
    networking.enableIPv6 = lib.mkDefault false;
    networking.wireguard.interfaces.fleet0 = {
      ips = [ "${cfg.address}/32" ];
      listenPort = cfg.port;
      inherit (cfg) privateKeyFile;
      generatePrivateKeyFile = false;
      peers = lib.mapAttrsToList (name: peer: {
        inherit (peer) publicKey;
        allowedIPs = [ "${peer.address}/32" ];
        persistentKeepalive = 25;
      } // (if runtimePeer peer then { inherit name; } else {
        endpoint = "${peer.endpointAddress}:${toString peer.port}";
      })) cfg.peers;
    };
    systemd.services = {
      wireguard-fleet0 = {
        after = cfg.secretUnits;
        requires = cfg.secretUnits;
      };
    } // lib.mapAttrs' (name: peer: lib.nameValuePair "overalls-fleet-endpoint-${name}" {
      # @cc [owner:ghuntley,label:security] fleet-runtime-endpoints
      # A peer whose physical endpoint is runtime data MUST receive it only
      # after its publishing units validated it, and MUST receive it again
      # whenever its WireGuard peer unit is restarted.
      description = "Set the runtime WireGuard endpoint of fleet peer ${name}";
      after = [ (peerUnit name) ] ++ cfg.endpointUnits;
      requires = [ (peerUnit name) ] ++ cfg.endpointUnits;
      partOf = [ (peerUnit name) ] ++ cfg.endpointUnits;
      wantedBy = [ (peerUnit name) "multi-user.target" ];
      path = [ pkgs.wireguard-tools ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.escapeShellArgs [ "${pkgs.python3}/bin/python3" "${./fleet-endpoint.py}"
          "--interface" "fleet0" "--public-key" peer.publicKey
          "--address-file" peer.endpointAddressFile "--port" (toString peer.port) ];
      };
    }) runtimePeers;
    overalls.runtimeFirewall.rules = lib.listToAttrs (map (peer: lib.nameValuePair "fleet-handshake-${peer.name}" {
      source = peer.endpointAddress;
      sourceFile = peer.endpointAddressFile;
      destination = cfg.endpointAddress;
      destinationFile = cfg.endpointAddressFile;
      protocol = "udp";
      ports = [ cfg.port ];
      comment = "Fleet WireGuard handshake from ${peer.name}";
      units = cfg.endpointUnits;
    }) (lib.filter handshakeRuntime (lib.mapAttrsToList (name: peer: peer // { inherit name; }) cfg.peers)));
    networking.firewall = {
      # This authenticated internal transport is an explicit exception to the
      # fleet perimeter's suppression of ordinary service firewall additions.
      extraInputRules = lib.mkIf config.networking.nftables.enable (perimeterPriority
        (lib.concatMapStringsSep "\n" (rule:
          lib.optionalString (rule.interface != null) ''iifname "${rule.interface}" ''
          + "ip saddr ${rule.source} ip daddr ${rule.destination} ${rule.protocol} dport ${toString rule.port} accept") rules));
      extraCommands = lib.mkIf (!config.networking.nftables.enable) (perimeterPriority (
        lib.concatMapStringsSep "\n" (rule:
          "iptables -w -A nixos-fw " + lib.optionalString (rule.interface != null) "-i ${rule.interface} "
          + "-s ${rule.source} -d ${rule.destination} -p ${rule.protocol} --dport ${toString rule.port} -j nixos-fw-accept") rules
        + "\n" + ''
          iptables -w -C FORWARD -i fleet0 -j DROP 2>/dev/null || iptables -w -I FORWARD 1 -i fleet0 -j DROP
          iptables -w -C FORWARD -o fleet0 -j DROP 2>/dev/null || iptables -w -I FORWARD 1 -o fleet0 -j DROP
        ''));
      extraStopCommands = lib.mkIf (!config.networking.nftables.enable) ''
        iptables -w -D FORWARD -i fleet0 -j DROP 2>/dev/null || true
        iptables -w -D FORWARD -o fleet0 -j DROP 2>/dev/null || true
      '';
    };
    networking.nftables.tables.overalls-fleet = lib.mkIf config.networking.nftables.enable {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority -100; policy accept;
          iifname "fleet0" counter drop
          oifname "fleet0" counter drop
        }
      '';
    };
  };
}

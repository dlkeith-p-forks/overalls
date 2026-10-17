{ config, lib, ... }:
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
  rules = lib.concatMap (peer:
    [{ source = peer.endpointAddress; destination = cfg.endpointAddress; protocol = "udp"; port = cfg.port; interface = null; }]
    ++ map (port: { source = peer.address; destination = cfg.address; protocol = "tcp"; inherit port; interface = "fleet0"; }) cfg.tcpPorts
  ) peers;
in {
  options.overalls.fleetNetwork = {
    enable = lib.mkEnableOption "IPv4-only host fleet WireGuard transport";
    address = mkOption { type = addressType; description = "Unique host address in the dedicated 10.90.0.0/24 fleet network."; };
    endpointAddress = mkOption { type = paths.ipv4; description = "Physical IPv4 destination admitted for WireGuard handshakes."; };
    port = mkOption { type = types.port; default = 51820; };
    privateKeyFile = mkOption { type = paths.privatePath; description = "Runtime private WireGuard key; never embedded in the store."; };
    secretUnits = mkOption { type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service"); default = []; };
    tcpPorts = mkOption { type = types.listOf types.port; default = []; description = "Local fleet services admitted only from configured tunnel peers."; };
    peers = mkOption {
      default = {};
      type = types.attrsOf (types.submodule {
        options = {
          address = mkOption { type = addressType; };
          endpointAddress = mkOption { type = paths.ipv4; };
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
    ];
    networking.enableIPv6 = lib.mkDefault false;
    networking.wireguard.interfaces.fleet0 = {
      ips = [ "${cfg.address}/32" ];
      listenPort = cfg.port;
      inherit (cfg) privateKeyFile;
      generatePrivateKeyFile = false;
      peers = map (peer: {
        inherit (peer) publicKey;
        allowedIPs = [ "${peer.address}/32" ];
        endpoint = "${peer.endpointAddress}:${toString peer.port}";
        persistentKeepalive = 25;
      }) peers;
    };
    systemd.services.wireguard-fleet0 = {
      after = cfg.secretUnits;
      requires = cfg.secretUnits;
    };
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

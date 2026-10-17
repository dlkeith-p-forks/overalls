{ config, lib, ... }:
let
  cfg = config.overalls.fleetFirewall;
  hosts = lib.attrValues cfg.allowedHosts;
  services = lib.attrValues cfg.publicServices;
  validIPv4 = address:
    let octets = lib.splitString "." address;
    in builtins.length octets == 4 && lib.all (octet:
      let value = lib.toInt octet;
      in value >= 0 && value <= 255 && toString value == octet) octets;
  nftRules = lib.concatMapStringsSep "\n" (host:
    ''ip saddr ${host.address} meta l4proto { tcp, udp } accept comment "${host.comment}"'') hosts;
  publicNftRules = lib.concatMapStringsSep "\n" (service:
    lib.concatMapStringsSep "\n" (rule:
      ''ip daddr ${service.address} ${rule.protocol} dport ${toString rule.port} accept comment "${service.comment}"'')
      (map (port: { protocol = "tcp"; inherit port; }) service.tcpPorts
        ++ map (port: { protocol = "udp"; inherit port; }) service.udpPorts)) services;
  iptablesRules = lib.concatMapStringsSep "\n" (host:
    lib.concatMapStringsSep "\n" (protocol:
      "iptables -w -A nixos-fw -s ${host.address} -p ${protocol} -m comment --comment ${lib.escapeShellArg host.comment} -j nixos-fw-accept"
    ) [ "tcp" "udp" ]) hosts;
  publicIptablesRules = lib.concatMapStringsSep "\n" (service:
    lib.concatMapStringsSep "\n" (rule:
      "iptables -w -A nixos-fw -d ${service.address} -p ${rule.protocol} --dport ${toString rule.port} -m comment --comment ${lib.escapeShellArg service.comment} -j nixos-fw-accept"
    ) (map (port: { protocol = "tcp"; inherit port; }) service.tcpPorts
        ++ map (port: { protocol = "udp"; inherit port; }) service.udpPorts)) services;
in
{
  options.overalls.fleetFirewall = {
    enable = lib.mkEnableOption "fleet-wide Tailscale and reviewed-source firewall access";
    allowedHosts = lib.mkOption {
      default = import ../../policy/network/allowed-hosts.nix;
      description = "Named IPv4 sources allowed to reach every fleet host over TCP and UDP.";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          address = lib.mkOption {
            type = lib.types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}";
            description = "Reviewed IPv4 source address.";
          };
          comment = lib.mkOption {
            type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9 ._()/-]{0,95}";
            description = "Required human-readable owner or purpose for this grant.";
          };
        };
      });
    };
    publicServices = lib.mkOption {
      default = {};
      description = "Named destination-scoped listeners admitted from any IPv4 source; each needs an explicit local address, at least one TCP or UDP port, and a reviewed comment.";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          address = lib.mkOption {
            type = lib.types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}";
            description = "Explicit local IPv4 destination address; never a wildcard.";
          };
          tcpPorts = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [];
            description = "TCP ports reachable from any source at this address.";
          };
          udpPorts = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [];
            description = "UDP ports reachable from any source at this address.";
          };
          comment = lib.mkOption {
            type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9 ._()/-]{0,95}";
            description = "Required human-readable owner or purpose for this listener.";
          };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = lib.all (host: validIPv4 host.address) hosts;
        message = "Fleet firewall grants require canonical IPv4 source addresses."; }
      { assertion = lib.length (lib.unique (map (host: host.address) hosts)) == lib.length hosts;
        message = "Fleet firewall grants require unique IPv4 source addresses."; }
      { assertion = lib.all (service: validIPv4 service.address && service.address != "0.0.0.0") services;
        message = "Public service listeners require canonical explicit IPv4 destination addresses."; }
      { assertion = lib.length (lib.unique (map (service: service.address) services)) == lib.length services;
        message = "Public service listeners require unique IPv4 destination addresses."; }
      { assertion = lib.all (service: service.tcpPorts != [] || service.udpPorts != []) services;
        message = "Public service listeners require at least one TCP or UDP port."; }
      { assertion = lib.all (service:
          lib.length (lib.unique service.tcpPorts) == lib.length service.tcpPorts
          && lib.length (lib.unique service.udpPorts) == lib.length service.udpPorts) services;
        message = "Public service listeners require unique ports per protocol."; }
    ];

    # @cc [owner:ghuntley,label:security] fleet-network-source-access
    # Traffic arriving on tailscale0 MUST be trusted. Every reviewed public IPv4
    # source MUST be allowed to reach all TCP and UDP listeners on every fleet
    # host; no other protocol receives that source grant. Global port options
    # and ordinary service firewall contributions MUST remain suppressed;
    # explicitly force-priority authenticated transport rules and reviewed
    # destination-scoped public service listeners admitted through publicServices
    # MAY coexist. A public service entry MUST NOT broaden into a wildcard
    # destination or an unrelated address.
    networking.firewall = {
      enable = true;
      trustedInterfaces = lib.mkForce [ "lo" "tailscale0" ];
      allowedTCPPorts = lib.mkForce [];
      allowedUDPPorts = lib.mkForce [];
      allowedTCPPortRanges = lib.mkForce [];
      allowedUDPPortRanges = lib.mkForce [];
      extraInputRules = lib.mkForce (lib.optionalString config.networking.nftables.enable
        (lib.concatStringsSep "\n" (lib.filter (rules: rules != "") [ nftRules publicNftRules ])));
      extraCommands = lib.mkForce (lib.optionalString (!config.networking.nftables.enable)
        (lib.concatStringsSep "\n" (lib.filter (rules: rules != "") [ iptablesRules publicIptablesRules ])));
    };
  };
}

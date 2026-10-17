{ lib, config, address, tcpPorts ? [], udpPorts ? [], udpPortRanges ? [] }:
let
  wildcard = address == "0.0.0.0";
  rules = lib.concatMap (protocol: map (port: { inherit protocol port; })
    (if protocol == "tcp" then tcpPorts else udpPorts)) [ "tcp" "udp" ];
in
# @cc [owner:ghuntley,label:security] listener-firewall-destination
# Explicit listener addresses MUST open only that IPv4 destination. Wildcard
# listeners may open ports globally. Both firewall backends MUST agree.
{
  allowedTCPPorts = lib.optionals wildcard tcpPorts;
  allowedUDPPorts = lib.optionals wildcard udpPorts;
  allowedUDPPortRanges = lib.optionals wildcard udpPortRanges;
  extraInputRules = lib.mkIf (!wildcard && config.networking.nftables.enable)
    (lib.concatMapStringsSep "\n" (rule:
      "ip daddr ${address} ${rule.protocol} dport ${toString rule.port} accept") rules
      + lib.concatMapStrings (range:
        "\nip daddr ${address} udp dport ${toString range.from}-${toString range.to} accept") udpPortRanges);
  extraCommands = lib.mkIf (!wildcard && !config.networking.nftables.enable)
    (lib.concatMapStringsSep "\n" (rule:
      "iptables -w -A nixos-fw -d ${address} -p ${rule.protocol} --dport ${toString rule.port} -j nixos-fw-accept") rules
      + lib.concatMapStrings (range:
        "\niptables -w -A nixos-fw -d ${address} -p udp --dport ${toString range.from}:${toString range.to} -j nixos-fw-accept") udpPortRanges);
}

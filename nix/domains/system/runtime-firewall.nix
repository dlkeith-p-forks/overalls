{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.overalls.runtimeFirewall;
  paths = import ./types.nix { inherit lib; };
  chain = "overalls-runtime";
  nft = config.networking.nftables.enable;
  backendUnit = if nft then "nftables.service" else "firewall.service";
  rules = lib.attrValues cfg.rules;
  units = lib.unique (lib.concatMap (rule: rule.units) rules);
  perimeter = lib.attrByPath [ "overalls" "fleetFirewall" "enable" ] false config;
  perimeterPriority = if perimeter then lib.mkForce else value: value;
  runtimeFile = types.nullOr (types.strMatching "/run/[A-Za-z0-9_./-]+");
  specification = pkgs.writeText "overalls-runtime-firewall.json" (builtins.toJSON {
    inherit chain;
    backend = if nft then "nftables" else "iptables";
    rules = lib.mapAttrsToList (name: rule: {
      inherit name;
      inherit (rule) source sourceFile destination destinationFile protocol ports interface comment optional;
    }) cfg.rules;
  });
  script = action: lib.escapeShellArgs [ "${pkgs.python3}/bin/python3" "${./runtime-firewall.py}" action specification ];
in
{
  options.overalls.runtimeFirewall.rules = mkOption {
    default = {};
    description = "Input accept rules whose source or destination IPv4 address is runtime data (for example a decrypted SOPS bundle) kept out of the repository and the Nix store.";
    type = types.attrsOf (types.submodule {
      options = {
        source = mkOption { type = types.nullOr paths.ipv4; default = null; description = "Static IPv4 source."; };
        sourceFile = mkOption { type = runtimeFile; default = null; description = "Runtime file holding the IPv4 source."; };
        destination = mkOption { type = types.nullOr paths.ipv4; default = null; description = "Static local IPv4 destination."; };
        destinationFile = mkOption { type = runtimeFile; default = null; description = "Runtime file holding the local IPv4 destination."; };
        protocol = mkOption { type = types.enum [ "tcp" "udp" "any" ]; description = "tcp or udp with ports, or any for every TCP and UDP port."; };
        ports = mkOption { type = types.listOf types.port; default = []; };
        interface = mkOption { type = types.nullOr (types.strMatching "[a-z][a-z0-9]{0,14}"); default = null; };
        comment = mkOption { type = types.strMatching "[A-Za-z0-9][A-Za-z0-9 ._()/-]{0,95}"; };
        optional = mkOption {
          type = types.bool;
          default = false;
          description = "Skip only this rule while its runtime file is absent; a present but malformed address still empties the chain.";
        };
        units = mkOption {
          type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service");
          description = "Units that publish the runtime files; the rules follow them.";
        };
      };
    });
  };

  config = lib.mkIf (cfg.rules != {}) {
    assertions = [
      { assertion = lib.all (rule: rule.sourceFile != null || rule.destinationFile != null) rules;
        message = "Runtime firewall rules need a runtime source or destination; static rules belong to their module."; }
      { assertion = lib.all (rule: (rule.source == null || rule.sourceFile == null)
          && (rule.destination == null || rule.destinationFile == null)) rules;
        message = "Runtime firewall rules take a static or a runtime address per side, not both."; }
      { assertion = lib.all (rule: (rule.protocol == "any") == (rule.ports == [])
          && lib.unique rule.ports == rule.ports) rules;
        message = "Runtime firewall rules need unique ports for tcp or udp, and none for any."; }
      { assertion = lib.all (rule: rule.units != []) rules;
        message = "Runtime firewall rules must name the units that publish their addresses."; }
    ];

    # @cc [owner:ghuntley,label:security] runtime-firewall-addresses
    # Rules whose addresses are runtime data MUST live in one dedicated chain
    # reached by a static jump from the input allow path. The chain MUST admit
    # nothing until the refill unit has validated every runtime address; the
    # refill MUST flush before adding, follow the publishing units, and run
    # again after every firewall reload or restart on both backends, so a
    # rotation replaces rules and a malformed address leaves its rule absent.
    networking.nftables.tables.nixos-fw.content = lib.mkIf nft ''
      chain ${chain} {
      }
    '';
    networking.firewall.extraInputRules = lib.mkIf nft (perimeterPriority "jump ${chain}");
    networking.firewall.extraCommands = lib.mkIf (!nft) (perimeterPriority ''
      iptables -w -N ${chain} 2>/dev/null || true
      iptables -w -A nixos-fw -j ${chain}
    '');

    systemd.services.overalls-runtime-firewall = {
      description = "Admit runtime-address firewall rules";
      after = [ backendUnit ] ++ units;
      requires = units;
      partOf = [ backendUnit ] ++ units;
      wantedBy = [ "multi-user.target" backendUnit ];
      restartTriggers = [ specification ];
      unitConfig.ReloadPropagatedFrom = [ backendUnit ];
      path = if nft then [ pkgs.nftables ] else [ pkgs.iptables ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = script "apply";
        ExecReload = script "apply";
        ExecStop = script "flush";
      };
    };
  };
}

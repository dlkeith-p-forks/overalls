{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.overalls.fleetAddresses;
  localTypes = import ./types.nix { inherit lib; };
  directory = "/run/overalls-secrets/fleet-addresses";
  bundle = config.services.overallsSecrets.bundles.fleet-addresses;
  encrypted = cfg.encryptedFile != null;
  logical = types.strMatching "[a-z][A-Za-z0-9]{0,31}";
  python = "${pkgs.python3}/bin/python3";
  specification = pkgs.writeText "overalls-fleet-addresses.json" (builtins.toJSON {
    inherit directory;
    inherit (cfg) names uplink;
  });
in
{
  options.overalls.fleetAddresses = {
    enable = mkEnableOption "fleet public addresses delivered through SOPS instead of the repository";
    encryptedFile = mkOption {
      type = types.nullOr localTypes.absolutePath;
      default = null;
      description = "Shared SOPS document (project overalls-fleet-addresses); null on a base system, which uses only the uplink recovery copy.";
    };
    names = mkOption {
      type = types.attrsOf (types.strMatching "[A-Z][A-Z0-9_]{0,62}_(IPV4|PREFIX)");
      default = {};
      description = "Logical name to secret name; secrets ending _IPV4 are addresses and _PREFIX are prefix lengths.";
    };
    files = mkOption {
      type = types.attrsOf types.str;
      readOnly = true;
      default = lib.mapAttrs (name: _: "${directory}/${name}") cfg.names;
      description = "Runtime file per logical name, for consumers such as firewall rules and listeners.";
    };
    environmentFile = mkOption {
      type = types.str;
      readOnly = true;
      default = "${directory}/addresses.env";
      description = "EnvironmentFile with every selected secret by its secret name.";
    };
    unit = mkOption {
      type = types.str;
      readOnly = true;
      default = "overalls-fleet-addresses.service";
      description = "Unit after which every runtime address has been validated.";
    };
    uplink = mkOption {
      default = null;
      description = "Static uplink addressing applied as a runtime networkd drop-in.";
      type = types.nullOr (types.submodule {
        options = {
          network = mkOption { type = types.strMatching "[A-Za-z0-9][A-Za-z0-9_.-]{0,63}"; };
          addresses = mkOption { type = types.nonEmptyListOf logical; };
          prefix = mkOption { type = logical; };
          gateway = mkOption { type = logical; };
          hostRoutes = mkOption { type = types.listOf logical; default = []; description = "Addresses routed as /32 through the gateway."; };
          recoveryFile = mkOption {
            type = types.str;
            readOnly = true;
            default = "/var/lib/overalls-host/uplink.conf";
            description = "Last applied drop-in, used when the document cannot be decrypted, and written by host installation.";
          };
        };
      });
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      { assertion = encrypted || cfg.uplink != null;
        message = "Fleet addresses need a document or an uplink recovery copy."; }
      { assertion = cfg.uplink == null || !encrypted || lib.all (name: cfg.names ? ${name})
          ([ cfg.uplink.prefix cfg.uplink.gateway ] ++ cfg.uplink.addresses ++ cfg.uplink.hostRoutes);
        message = "Every uplink name must be a declared fleet address name."; }
    ];

    services.overallsSecrets = mkIf encrypted {
      enable = true;
      bundles.fleet-addresses = {
        inherit (cfg) encryptedFile;
        outputs = lib.mapAttrs (_: secret: { format = "raw"; secrets = [ secret ]; }) cfg.names // {
          "addresses.env" = { format = "environment"; secrets = lib.unique (lib.attrValues cfg.names); };
        };
      };
    };

    # @cc [owner:ghuntley,label:security;deployment] fleet-addresses-from-sops
    # Fleet public addresses MAY live only in the shared SOPS document. Every
    # value MUST be validated before any consumer starts; a malformed or
    # missing document MUST fail the unit so dependent listeners and rules
    # stay closed. Rotation is a document change only.
    systemd.services.overalls-fleet-addresses = mkIf encrypted {
      description = "Validate the SOPS-delivered fleet addresses";
      after = [ bundle.unit ];
      requires = [ bundle.unit ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ specification ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.escapeShellArgs [ python "${./fleet-addresses.py}" "validate" specification ];
      };
    };

    # @cc [owner:ghuntley,label:recovery;security] fleet-uplink-recovery-copy
    # Static uplink addressing MUST come from the document as a runtime
    # networkd drop-in, never from the repository. Each applied drop-in MUST
    # be kept as a root-only recovery copy, and the unit MUST fall back to that
    # copy when the document cannot be read, so a secret failure never strands
    # the host. Restarting MUST replace the drop-in atomically, not remove it.
    systemd.services.overalls-fleet-uplink = mkIf (cfg.uplink != null) {
      description = "Apply the fleet uplink addresses";
      after = [ "systemd-networkd.service" ] ++ lib.optional encrypted bundle.unit;
      wants = [ "systemd-networkd.service" ] ++ lib.optional encrypted bundle.unit;
      before = [ "network-online.target" "systemd-networkd-wait-online.service" ];
      wantedBy = [ "multi-user.target" "network-online.target" ];
      restartTriggers = [ specification ] ++ lib.optional encrypted cfg.encryptedFile;
      path = [ config.systemd.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.escapeShellArgs [ python "${./fleet-addresses.py}" "uplink" specification ];
      };
    };
  };
}

{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.overalls.publicAddress;
  localTypes = import ./types.nix { inherit lib; };
  bundle = config.services.overallsSecrets.bundles.public-address;
in
{
  options.overalls.publicAddress = {
    enable = mkEnableOption "a host public address delivered through SOPS instead of the repository";
    encryptedFile = mkOption {
      type = localTypes.absolutePath;
      description = "Host-bound SOPS document with PUBLIC_IPV4 and PUBLIC_IPV6 (address/prefix) under project overalls-public-address.";
    };
    network = mkOption {
      type = types.strMatching "[A-Za-z0-9][A-Za-z0-9_.-]{0,63}";
      description = "systemd-networkd network (without .network) that receives the IPv6 address.";
    };
    ipv4File = mkOption {
      type = types.str;
      readOnly = true;
      default = "/run/overalls-secrets/public-address/ipv4";
      description = "Runtime file holding the decrypted IPv4 address, for destination-scoped listeners.";
    };
    unit = mkOption {
      type = types.str;
      readOnly = true;
      default = "overalls-public-address.service";
      description = "Unit after which the runtime addresses are validated and applied.";
    };
  };

  config = mkIf cfg.enable {
    services.overallsSecrets.enable = true;
    services.overallsSecrets.bundles.public-address = {
      inherit (cfg) encryptedFile;
      outputs = {
        ipv4 = { format = "raw"; secrets = [ "PUBLIC_IPV4" ]; };
        ipv6 = { format = "raw"; secrets = [ "PUBLIC_IPV6" ]; };
      };
    };

    # @cc [owner:ghuntley,label:security;deployment] public-address-from-sops
    # A host's public addresses MAY live only in its host-bound SOPS document.
    # The unit MUST validate both values before use, MUST apply the IPv6
    # address only as a runtime networkd drop-in outside the Nix store, and a
    # malformed or missing document MUST fail the unit so dependent public
    # listeners stay closed. Rotating the address is a document change only.
    systemd.services.overalls-public-address = {
      description = "Apply the SOPS-delivered public addresses";
      after = [ bundle.unit "systemd-networkd.service" ];
      requires = [ bundle.unit ];
      wants = [ "systemd-networkd.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ cfg.encryptedFile ];
      path = [ config.systemd.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.escapeShellArgs [ "${pkgs.python3}/bin/python3" "${./public-address.py}"
          "--bundle" bundle.directory "--network" cfg.network ];
        ExecStopPost = lib.escapeShellArgs [ "${pkgs.python3}/bin/python3" "${./public-address.py}"
          "--remove" "--bundle" bundle.directory "--network" cfg.network ];
      };
    };
  };
}

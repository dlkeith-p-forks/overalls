{ lib, pkgs }:
let
  inherit (lib) mkOption types;
  paths = import ./types.nix { inherit lib; };
  # A runtime file under /run, usable as a LoadCredential source (no ':').
  runtimeFile = types.addCheck paths.privatePath (value:
    lib.hasPrefix "/run/" value && !lib.hasInfix ":" value);
  unit = types.strMatching "[a-zA-Z0-9_.@-]+\\.service";
  # Prints the canonical explicit IPv4 address held in a credential file, or
  # fails without echoing the rejected value (fleet addresses are secrets).
  validate = ''
    overalls_bind_address() {
      local value octet
      value="$(${pkgs.coreutils}/bin/tr -d ' \t\r\n' < "$1")"
      if ! [[ "$value" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]]; then
        echo "Runtime bind address is not a canonical IPv4 address" >&2
        return 1
      fi
      for octet in "''${BASH_REMATCH[@]:1}"; do
        if [ "$octet" -gt 255 ]; then
          echo "Runtime bind address is not a canonical IPv4 address" >&2
          return 1
        fi
      done
      if [ "$value" = 0.0.0.0 ]; then
        echo "Runtime bind address must not be a wildcard" >&2
        return 1
      fi
      printf '%s' "$value"
    }
  '';
in
{
  # Options shared by services that bind either a static address or one
  # published at runtime by another unit (for example a decrypted SOPS bundle).
  options = { description, staticDefault ? "0.0.0.0" }: cfg: {
    bindAddress = mkOption {
      type = types.nullOr paths.ipv4;
      default = if cfg.bindAddressFile == null then staticDefault else null;
      defaultText = lib.literalExpression ''if bindAddressFile == null then "${staticDefault}" else null'';
      description = "Static IPv4 listener address for ${description}; null when bindAddressFile supplies it at runtime.";
    };
    bindAddressFile = mkOption {
      type = types.nullOr runtimeFile;
      default = null;
      description = "Runtime file under /run holding the canonical IPv4 listener address for ${description}, kept out of the repository and the Nix store.";
    };
    bindAddressUnit = mkOption {
      type = types.nullOr unit;
      default = null;
      description = "Unit that publishes bindAddressFile; ${description} starts after it and stops with it.";
    };
  };

  assertions = name: cfg: [
    { assertion = (cfg.bindAddress == null) != (cfg.bindAddressFile == null);
      message = "${name} requires exactly one of bindAddress or bindAddressFile."; }
    { assertion = (cfg.bindAddressFile == null) == (cfg.bindAddressUnit == null);
      message = "${name} bindAddressFile requires bindAddressUnit."; }
    { assertion = !cfg.openFirewall || cfg.bindAddress != null;
      message = "${name} openFirewall needs a static bindAddress; admit runtime addresses through the fleet firewall."; }
  ];

  # Unit wiring for a runtime address: ordering, stop propagation and the
  # credential the render step reads.
  # A file without its unit is refused by the assertions above.
  unitConfig = cfg: lib.optionalAttrs (cfg.bindAddressFile != null && cfg.bindAddressUnit != null) {
    after = [ cfg.bindAddressUnit ];
    requires = [ cfg.bindAddressUnit ];
  };
  credential = cfg: name: lib.optional (cfg.bindAddressFile != null) "${name}:${cfg.bindAddressFile}";

  # Shell that reads a bind address into a variable: the literal when static,
  # otherwise the validated credential.
  read = variable: cfg: credentialName:
    if cfg.bindAddressFile == null
    then "${variable}=${lib.escapeShellArg cfg.bindAddress}"
    else ''${variable}="$(overalls_bind_address "$CREDENTIALS_DIRECTORY/${credentialName}")"'';

  inherit validate;

  # Shell that writes template with .bind replaced by the shell variable
  # holding the validated address. The output is private to the service user.
  render = { template, output, variable ? "bind_address" }: ''
    ${pkgs.jq}/bin/jq --arg bind "''$${variable}" '.bind = $bind' ${template} > ${output}.new
    ${pkgs.coreutils}/bin/chmod 0600 ${output}.new
    ${pkgs.coreutils}/bin/mv -f ${output}.new ${output}
  '';
}

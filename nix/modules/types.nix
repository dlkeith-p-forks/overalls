{ lib }:
let
  inherit (lib) types;
  path = types.strMatching "/[a-zA-Z0-9_./:+-]+";
  absolutePath = types.addCheck path (value:
    !lib.any (part: builtins.elem part [ "" "." ".." ]) (lib.tail (lib.splitString "/" value)));
in
{
  # @cc [owner:ghuntley,label:security] private-path-no-store
  # Private paths MUST remain strings, exclude store paths and systemd/shell
  # specifiers, and reject ambiguous dot segments or repeated separators.
  privatePath = types.addCheck absolutePath (value: !lib.hasPrefix "/nix/store/" value);
  inherit absolutePath;
  # @cc [owner:ghuntley,label:security] canonical-ipv4-literal
  # Listener addresses MUST be canonical dotted IPv4 literals. Reject IPv6,
  # abbreviated addresses and leading-zero octets before rendering configuration.
  ipv4 = types.addCheck types.str (value:
    let parts = lib.splitString "." value;
    in builtins.length parts == 4 && lib.all (part:
      builtins.match "(0|[1-9][0-9]{0,2})" part != null && lib.toInt part <= 255) parts);
  identifier = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}";
  uuid = types.strMatching "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
}

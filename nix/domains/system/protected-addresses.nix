# Shared runtime rendering of Lilly's protected addresses for Lilly and Brady.
{ lib, files }:
let
  names = lib.imap0 (index: _: "protected-address-${toString index}") files;
  octet = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])";
in
{
  # @cc [owner:ghuntley,label:security] lilly-protected-runtime-addresses
  # Runtime protected addresses MUST arrive only as systemd credentials from
  # root-owned files, be canonical explicit unicast IPv4 addresses rendered as
  # /32 networks, and fail service startup when any value is missing or
  # malformed; they extend, never replace, the evaluated protected networks.
  credentials = lib.zipListsWith (name: file: "${name}:${file}") names files;
  jqArguments = lib.concatMapStringsSep " " (name:
    ''--rawfile ${lib.replaceStrings [ "-" ] [ "_" ] name} "$CREDENTIALS_DIRECTORY/${name}"'') names;
  # Appends the validated /32 networks to the protected list at `path`.
  jqFilter = path: if files == [] then "." else ''
    def runtime_address:
      sub("\\s+$"; "")
      | if test("^${octet}(\\.${octet}){3}$") and . != "0.0.0.0" and . != "255.255.255.255"
          and (startswith("127.") | not) and (split(".")[0] | tonumber) < 224
        then . + "/32"
        else error("invalid protected runtime address") end;
    ${path} += ([${lib.concatMapStringsSep ", " (name: "$" + lib.replaceStrings [ "-" ] [ "_" ] name) names}] | map(runtime_address))
  '';
}

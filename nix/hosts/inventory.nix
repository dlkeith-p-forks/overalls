{ lib, root ? ../../fleet/hosts }:
let
  names = builtins.attrNames (lib.filterAttrs (_: kind: kind == "directory") (builtins.readDir root));
  declarations = lib.genAttrs names (name:
    let host = builtins.fromJSON (builtins.readFile (root + "/${name}/host.json"));
    in assert lib.assertMsg (host.name == name) "Host directory and declaration name differ"; host);
  unique = values: builtins.length values == builtins.length (lib.unique values);
  hosts = assert lib.assertMsg (lib.all (name: builtins.match "[a-z][a-z0-9-]{0,27}" name != null && !lib.hasSuffix "-base" name) names) "Invalid or reserved host name";
    assert lib.assertMsg (unique (map (name: declarations.${name}.identity.hostId) names)) "Duplicate ZFS host ID";
    assert lib.assertMsg (unique (map (name: declarations.${name}.inventory.machine) names)) "Duplicate physical machine identity";
    assert lib.assertMsg (unique (lib.concatMap (name: map (key: lib.concatStringsSep " " (lib.take 2 (lib.splitString " " key))) declarations.${name}.identity.sshKeys) names)) "Duplicate host public key";
    declarations;
  documents = lib.concatMap (name: map (document: {
    inherit name document;
  }) hosts.${name}.credentials) names;
in {
  inherit hosts;
  secrets = {
    hosts = lib.mapAttrs (_: host: { sshKeys = host.identity.sshKeys; })
      (lib.filterAttrs (_: host: host.identity.sshKeys != []) hosts);
    documents = lib.foldl' (result: item:
      let old = result.${item.document.name} or { path = item.document.path; hosts = []; };
      in assert lib.assertMsg (old.path == item.document.path) "Conflicting encrypted document paths";
      result // { ${item.document.name} = old // { hosts = lib.unique (old.hosts ++ [ item.name ]); }; }
    ) {} documents;
  };
}

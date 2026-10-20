{ lib }:
let
  inventory = (import ../nix/platform/hosts/inventory.nix { inherit lib; }).hosts;
  keys = builtins.fromJSON (builtins.readFile ./builder-public-keys.json);
  # Both CPU counts were measured with nproc --all over inventory-pinned
  # administrative SSH on 2026-09-18. Guest budgets are not CPU discovery.
  endpoints = {
    # Builders are reached over Tailscale so no public address is evaluated.
    dungarees = { address = "100.120.189.15"; port = 2222; logicalCpus = 32; };
    overalls = { address = "100.117.30.53"; port = 2222; logicalCpus = 32; };
  };
in
# @cc [owner:ghuntley,label:security] fleet-builder-authority
# Host pins and encrypted document paths MUST derive from authoritative host
# inventory; CPU slots MUST reflect authenticated physical CPU observations.
# A host awaiting its installed identity (a base declaration) is not a builder.
lib.mapAttrs (name: endpoint: endpoint // {
  systems = [ "${inventory.${name}.inventory.arch}-linux" ];
  supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" "nested-kvm" ];
  clientPublicKeys = [ keys.${name} ];
  hostPublicKey = builtins.head inventory.${name}.identity.sshKeys;
  encryptedFile = let
    document = lib.findFirst (item: item.name == "${name}-remote-builders")
      (throw "Missing remote builder credential") inventory.${name}.credentials;
    path = ../. + ("/" + document.path);
  in assert lib.assertMsg (builtins.pathExists path) "Missing remote builder ciphertext"; "${path}";
}) (lib.filterAttrs (name: _: inventory.${name}.identity.sshKeys != []) endpoints)

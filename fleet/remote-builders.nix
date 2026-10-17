{ lib }:
let
  inventory = (import ../nix/hosts/inventory.nix { inherit lib; }).hosts;
  keys = builtins.fromJSON (builtins.readFile ./builder-public-keys.json);
  # Both CPU counts were measured with nproc --all over inventory-pinned
  # administrative SSH on 2026-09-18. Guest budgets are not CPU discovery.
  endpoints = {
    dungarees = { address = "136.243.69.35"; port = 2222; logicalCpus = 32; };
    overalls = { address = "136.243.69.55"; port = 2222; logicalCpus = 32; };
  };
in
# @cc [owner:ghuntley,label:security] fleet-builder-authority
# Host pins and encrypted document paths MUST derive from authoritative host
# inventory; CPU slots MUST reflect authenticated physical CPU observations.
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
}) endpoints

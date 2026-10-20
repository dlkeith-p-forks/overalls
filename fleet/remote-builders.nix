{ lib }:
let
  inventory = (import ../nix/platform/hosts/inventory.nix { inherit lib; }).hosts;
  keys = builtins.fromJSON (builtins.readFile ./builder-public-keys.json);
  # CPU counts were measured with nproc --all over inventory-pinned
  # administrative SSH: Overalls on 2026-09-18, the replacement Dungarees and
  # Panterloons on 2026-10-20. Guest budgets are not CPU discovery.
  endpoints = {
    # Builders are reached over Tailscale so no public address is evaluated.
    dungarees = { address = "100.96.244.44"; port = 2222; logicalCpus = 96; };
    panterloons = { address = "100.98.214.120"; port = 2222; logicalCpus = 96; };
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

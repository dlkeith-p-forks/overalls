{ pkgs }:
let
  name = "overalls-windows-server-2025-8ca0a11f";
  narHash = "sha256-MTpVti0Mc+c3FzqjUJLfBAfEIW+plgP+HheZnVdPlUo=";
  # Sealed from the reviewed frozen windows-v1 source installation at
  # /nix/store/gpkrcddghwxj3g8wcd9qf69sjya4i1n8-lilly-windows-server-2025-x86_64.
  # Dereferencing its disk/firmware and copying its manifest produces exactly
  # three regular files, no store references and the reviewed recursive hash.
  # These pins describe artifact custody, not guest runtime acceptance.
  manifest = {
    version = 5;
    architecture = "x86_64";
    boot = {
      kind = "firmware";
      pci = true;
      firmware = {
        bytes = 4194304;
        sha256 = "261c6d43a4d74e6e7f4ea98390b35b6e0d90c511cf961e4b7abb60410b1c24a2";
      };
    };
    root = {
      format = "raw-gpt";
      bytes = 68719476736;
      sha256 = "2eee37f946e7688719b09b9e8b285431ef2332513f768c0b02a9e82c9e90fd05";
    };
    guest_agents = "windows-v1";
    minimum_memory_bytes = 2147483648;
    minimum_disk_bytes = 68719476736;
    workspace_source_version = 2;
  };
in
# @cc [owner:ghuntley,label:security;build;deployment] windows-published-exact-artifact
# Fleet Windows selection MUST resolve only this reviewed recursive fixed-output
# directory containing firmware, disk.raw and manifest.json without references.
# A missing signed-cache artifact MUST refuse with publication instructions;
# the fallback MUST NOT reinstall Windows, read a host path or weaken signature
# verification. The development source builder remains separately available.
pkgs.runCommand name {
  outputHash = narHash;
  outputHashMode = "recursive";
  allowedReferences = [ ];
  preferLocalBuild = true;
  passthru = {
    inherit narHash manifest;
    guestAgents = manifest.guest_agents;
  };
} ''
  cat >&2 <<'PUBLICATION'
    The reviewed Windows image ${name} is absent from the signed Overalls cache.
    Publish the sealed three-file directory with its reviewed recursive NAR hash:
      nix store add-path --name ${name} <sealed-directory>
    Verify the returned store path has NAR hash ${narHash}, then publish that
    exact path through the existing Overalls Cachix publisher. The sealed files
    are firmware, disk.raw and manifest.json; do not rebuild an installation or
    substitute a different Windows image. Signature verification stays required.
  PUBLICATION
  exit 1
''

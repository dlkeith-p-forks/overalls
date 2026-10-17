# @cc [owner:ghuntley,label:verification] test-driver-structured-script
# Large composed test scripts MUST build: the pinned NixOS test driver passes
# testScript as one environment string, which Linux caps at 128 KiB per
# string. Building only the driver derivation with structured attributes moves
# the script into the attrs file while keeping its ty and ruff checks.
pkgs:
pkgs.extend (final: prev: {
  runCommand = name: env: prev.runCommand name (
    env // prev.lib.optionalAttrs (prev.lib.hasPrefix "nixos-test-driver-" name) {
      __structuredAttrs = true;
    }
  );
})

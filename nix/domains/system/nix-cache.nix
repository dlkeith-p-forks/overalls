{ config, lib, ... }:
let
  cache = import ../../platform/nix-cache.nix;
in {
  # @cc [owner:ghuntley,label:security;deployment] signed-overalls-cachix
  # Every NixOS machine using the shared system catalog MUST retain the
  # pinned Overalls Cachix substituter and signing key, preserve the upstream
  # NixOS cache, and require signature verification for substituted paths.
  config = {
    assertions = [
      {
        assertion = config.nix.settings.require-sigs;
        message = "Overalls Cachix substitution requires Nix signature verification.";
      }
    ];
    nix.settings = {
      substituters = lib.mkAfter [ cache.substituter ];
      trusted-public-keys = lib.mkAfter [ cache.publicKey ];
      require-sigs = lib.mkDefault true;
      fallback = lib.mkDefault true;
    };
  };
}

{ ... }:
{
  # @cc [owner:ghuntley,label:security] fleet-distrust-emudhra-roots
  # Every NixOS system Overalls builds (hosts, the kexec installer and NixOS
  # guests) MUST distrust the roots chaining to the eight eMudhra intermediates
  # whose keys leaked in October 2026. Upstream nixos-26.05 appends the same
  # names in security/ca.nix (nixpkgs 7816d39); delete this module once the
  # pinned nixpkgs contains that change.
  security.pki.caCertificateBlacklist = [
    "Comodo AAA Services root"
    "emSign ECC Root CA - G3"
    "emSign Root CA - C1"
    "emSign ECC Root CA - C3"
  ];
}

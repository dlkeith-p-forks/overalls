{ overallsPackages }:
# @cc [owner:ghuntley,label:deployment] fleet-shared-guest-artifacts
# Selected catalog entries MUST be staged identically on every worker using this
# deployment package set, including platform public roots and current editor
# capability. Explicit retained-native staging may additionally preserve exact
# historical images for in-flight provisioning; it MUST NOT change this selection
# or grant a historical image new capabilities.
[
  { name = "NixOS"; package = overallsPackages.guest; }
  { name = "Ubuntu 26.04 LTS"; package = overallsPackages.ubuntuGuest; }
  { name = "Arch Linux"; package = overallsPackages.archGuest; }
  { name = "AlmaLinux"; package = overallsPackages.almaLinuxGuest; }
  { name = "Android SDK (NixOS)"; package = overallsPackages.androidGuest; }
]
# Only separately promoted native packages enter the catalog. Source receipts,
# staging images and assembly kits retain false admission flags; the promoted
# package binds exact reviewed artifacts and native machine evidence.
 ++ builtins.filter (entry: entry.package.passthru.nativeAdmission or false) [
  { name = "FreeBSD 14.3"; package = overallsPackages.freebsdGuest; }
  # The installable image is OmniOS, while its protocol family is illumos.
  { name = "OmniOS r151050"; package = overallsPackages.illumosGuest; }
]
 ++ [
  # Windows installation is not byte-stable (ADR-0171). Both staging and
  # registration consume the same sealed recursive-hash pin through the signed
  # cache; a cache miss refuses instead of installing a different image.
  # The unselected windows-editor-v1 candidate is intentionally absent until
  # its native custody and authenticated browser evidence are reviewed.
  { name = "Windows Server 2025"; package = overallsPackages.windowsGuestPublished; }
]

{ overallsPackages }:
# @cc [owner:ghuntley,label:deployment] fleet-shared-guest-artifacts
# Worker staging and control-plane registration MUST consume this same image
# list with the same deployment package set, including platform public roots
# and the current immutable browser-editor capability in both guest families.
[
  { name = "NixOS"; package = overallsPackages.guest; }
  { name = "Ubuntu 26.04 LTS"; package = overallsPackages.ubuntuGuest; }
  { name = "Arch Linux"; package = overallsPackages.archGuest; }
  { name = "AlmaLinux"; package = overallsPackages.almaLinuxGuest; }
]
# Native entries stay out of the catalog until their cross-built kernel and
# agent package have a positive admission receipt.  Keeping the constructors
# available in `nix/packages` lets evaluation and source-pin checks run without
# making an unavailable image launchable through the fleet catalog.
 ++ builtins.filter (entry: entry.package.passthru.nativeAdmission or false) [
  { name = "FreeBSD 14.3"; package = overallsPackages.freebsdGuest; }
  # The installable image is OmniOS, while its protocol family is illumos.
  { name = "OmniOS r151050"; package = overallsPackages.illumosGuest; }
]
 ++ [
  # Firmware-booted windows-v1 image (ADR-0171). Its installation is not
  # byte-stable, so it is built once and copied to both hosts before this entry
  # lands.
  { name = "Windows Server 2025"; package = overallsPackages.windowsGuestAgents; }
]

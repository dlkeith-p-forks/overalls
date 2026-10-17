{ pkgs, mkUbuntuGuest, terminald, lyraLinux }:
import ../foreign-linux.nix {
  inherit pkgs mkUbuntuGuest terminald lyraLinux;
  distribution = "almalinux";
  defaultImageName = "lilly-almalinux-x86_64";
  source = pkgs.fetchurl {
    url = "https://vault.almalinux.org/10.1/cloud/x86_64/images/AlmaLinux-10-GenericCloud-ext4-10.1-20260518.0.x86_64.qcow2";
    hash = "sha256-1W9GQfgu9mLOfEzq/VJ0Dkm5h99r9iU5Ii4HCHcw2F8=";
  };
  sourceFormat = "qcow2-ext4";
}

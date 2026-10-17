{ pkgs, mkUbuntuGuest, terminald, lyraLinux }:
import ../foreign-linux.nix {
  inherit pkgs mkUbuntuGuest terminald lyraLinux;
  distribution = "arch";
  defaultImageName = "lilly-archlinux-x86_64";
  source = pkgs.fetchurl {
    url = "https://geo.mirror.pkgbuild.com/iso/2026.10.01/archlinux-bootstrap-2026.10.01-x86_64.tar.zst";
    hash = "sha256-DJyXt6WKigI8ngf4TLMHqegAbmXY/EwXuD3cgBC0XBA=";
  };
  sourceFormat = "arch-bootstrap";
}

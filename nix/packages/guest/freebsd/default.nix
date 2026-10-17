{ pkgs, firmware ? (import ../windows/firmware.nix { inherit pkgs; }).fd }:
let native = import ../native.nix { inherit pkgs firmware; };
in native.mkFreeBSD

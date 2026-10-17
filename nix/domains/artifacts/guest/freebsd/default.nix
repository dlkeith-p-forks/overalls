{ pkgs, firmware ? (import ../windows/firmware.nix { inherit pkgs; }).fd, nativeAgents ? null }:
let native = import ../native.nix { inherit pkgs firmware nativeAgents; };
in native.mkFreeBSD

{ pkgs }:
pkgs.writeShellApplication {
  name = "ubuntu-lock";
  runtimeInputs = [ pkgs.python3 pkgs.apt pkgs.gnupg ];
  text = ''exec python3 ${./.}/update-lock.py "$@"'';
}

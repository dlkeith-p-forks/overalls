{ pkgs, module }:
let
  inherit (pkgs) lib;
  key = builtins.head (import ../../../users.nix).ghuntley.sshKeys;
in
pkgs.testers.runNixOSTest {
  name = "overalls-fleet-access";
  defaults = {
    imports = [ module ];
    system.stateVersion = "26.05";
    virtualisation.memorySize = 768;
    virtualisation.qemu.forceAccel = lib.mkForce true;
    overalls.access = {
      enable = true;
      users = lib.mkForce {
        operator = { login = true; admin = true; sshKeys = [ key ]; };
        reader = { login = true; group = "readers"; extraGroups = [ "reports" ]; sshKeys = [ key ]; };
        recovery = { secretRecovery = true; sshKeys = [ key ]; };
      };
    };
    environment.systemPackages = [ pkgs.openssh pkgs.util-linux ];
  };
  nodes = {
    primary = {
      system.switch.enable = true;
      specialisation.revoked.configuration.overalls.access.users = lib.mkOverride 40 {
        operator = { login = true; admin = true; sshKeys = [ key ]; };
        reader = { login = true; group = "users"; sshKeys = [ key ]; };
      };
      specialisation.removed.configuration.overalls.access.users = lib.mkOverride 40 {
        operator = { login = true; admin = true; sshKeys = [ key ]; };
      };
    };
    peer.services.openssh.ports = [ 22 2222 ];
  };
  testScript = builtins.readFile ./driver.py;
}

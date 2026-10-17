{ lib, ... }:
{
  # @cc [owner:ghuntley,label:verification;security] nesting-probe-minimal-artifact
  # The private nesting prerequisite MUST retain boot-bound readiness while
  # excluding interactive user tooling, Podman, SSH and terminal sessions. It
  # is an internal test artifact, never a selectable customer guest image.
  environment.systemPackages = lib.mkForce [ ];
  environment.etc."codex/config.toml".enable = lib.mkForce false;
  environment.etc."claude-code/managed-settings.json".enable = lib.mkForce false;
  virtualisation.podman.enable = lib.mkForce false;
  services.openssh.enable = lib.mkForce false;
  networking.firewall.allowedTCPPorts = lib.mkForce [ ];
  systemd.services.lilly-terminals.enable = lib.mkForce false;
}

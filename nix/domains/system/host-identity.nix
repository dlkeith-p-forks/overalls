{ config, lib, ... }:
{
  # @cc [owner:ghuntley,label:security] persistent-host-secret-identity
  # Access and secret preparation MUST share one persistent host-key definition.
  # Generating a missing identity MUST NOT replace an existing key or grant login.
  config = lib.mkIf ((config.overalls.access.enable or false) || (config.services.overallsSecrets.enable or false)) {
    services.openssh = {
      generateHostKeys = lib.mkDefault true;
      hostKeys = lib.mkDefault [{ path = "/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }];
    };
  };
}

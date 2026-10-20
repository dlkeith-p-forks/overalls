{ config, lib, ... }:
let
  secret = name: ../../../secrets + "/${config.overalls.controlPlaneHost.name}-${name}.enc.json";
in
{
  # @cc [owner:ghuntley,label:security;deployment] overalls-private-service-custody
  # Ziggy and Galileo receive only their control credentials. Audi's private
  # frontend receives only the bundle-delivered fleet wildcard certificate; no
  # host holds issuance or signing authority. The root and intermediate keys
  # MUST stay recovery-only.
  services.ziggy.secretsFile = "${secret "ziggy"}";
  services.ziggy.enabledProviders = [ "openai" ];
  services.galileo.secretsFile = "${secret "galileo"}";
  services.audiPrivate = lib.mkIf (!config.overalls.controlPlaneHost.bootstrap) {
    enable = true;
    secretsFile = "${secret "audi-private"}";
    rootsFile = "${../../../secrets/private-services-root.pem}";
  };
}

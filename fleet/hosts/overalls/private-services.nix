{ ... }:
{
  # @cc [owner:ghuntley,label:security;deployment] overalls-private-service-custody
  # Ziggy and Galileo receive only their control credentials. Audi's private
  # frontend receives only the bundle-delivered fleet wildcard certificate; no
  # host holds issuance or signing authority. The root and intermediate keys
  # MUST stay recovery-only.
  services.ziggy.secretsFile = "${../../../secrets/overalls-ziggy.enc.json}";
  services.ziggy.enabledProviders = [ "openai" ];
  services.galileo.secretsFile = "${../../../secrets/overalls-galileo.enc.json}";
  services.audiPrivate = {
    enable = true;
    secretsFile = "${../../../secrets/overalls-audi-private.enc.json}";
    rootsFile = "${../../../secrets/private-services-root.pem}";
  };
}

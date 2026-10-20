{ config, lib, ... }:
let
  publicAddress = "204.168.188.91";
  origin = "notifications.overalls.dev";
in
{
  # Pin the uplink name so the discovery-derived exporter interface (eth0)
  # stays correct under NixOS predictable interface naming.
  systemd.network.links."10-uplink" = {
    matchConfig.MACAddress = "92:00:0a:36:0d:d5";
    linkConfig.Name = "eth0";
  };

  # @cc [owner:ghuntley,label:deployment;security] salopettes-susan-only
  # Salopettes MUST run only the Susan push relay (ADR-0224, ADR-0231), its
  # local PostgreSQL and the TLS proxy for the fixed origin. It MUST NOT enable
  # Marshall, Lilly, Porsche, Audi, Brady, Galileo, Ziggy or the Marshall proxy.
  assertions = [{
    assertion = config.services.susan.enable
      && !config.services.marshall.enable
      && !config.services.marshallProxy.enable
      && !config.services.lilly.enable
      && !config.services.porsche.enable
      && !config.services.audi.enable
      && !config.services.brady.enable
      && !config.services.galileo.enable
      && !config.services.ziggy.enable;
    message = "Salopettes runs only the Susan push relay.";
  }];

  services.susan = {
    enable = true;
    secretsFile = "${../../../secrets/overalls-susan.enc.json}";
    # Mila's bundle identifier and Android application id.
    apnsTopics = [ "dev.overalls.mila" ];
    fcmAppIds = [ "dev.overalls.mila" ];
  };

  # @cc [owner:ghuntley,label:security;deployment] salopettes-susan-tls-origin
  # The proxy MUST terminate publicly trusted TLS for the fixed Susan origin
  # only, forward to Susan's loopback listener, and keep no access log: Susan
  # never records client addresses (ADR-0224). Plain HTTP serves only ACME
  # challenges and the redirect.
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    logError = "stderr crit";
    virtualHosts.${origin} = {
      enableACME = true;
      forceSSL = true;
      listenAddresses = [ publicAddress ];
      extraConfig = ''
        access_log off;
        client_max_body_size 4k;
      '';
      locations."/".proxyPass = "http://127.0.0.1:${toString config.services.susan.port}";
    };
  };
  security.acme = {
    acceptTerms = true;
    defaults.email = "noreply@ghuntley.dev";
  };

  overalls.fleetFirewall.publicServices.susan = {
    address = publicAddress;
    tcpPorts = [ 80 443 ];
    comment = "Susan push relay HTTPS and ACME";
  };

  # Susan is small; keep store reclamation bounded for the 150 GiB root.
  services.overallsNixGc = {
    diskThresholdGiB = 30;
    maxFreedGiB = 60;
  };

  services.overallsFleetExporter.units = [ "susan.service" "nginx.service" "postgresql.service" ];
}

{ config, lib, ... }:
let
  inventory = (import ../nix/platform/hosts/inventory.nix { inherit lib; }).hosts;
  publicKeys = builtins.fromJSON (builtins.readFile ./fleet-public-keys.json);
  # Physical endpoints are fleet address names (nix/policy/network/fleet-addresses.nix);
  # the values arrive only through the shared fleet-addresses SOPS document.
  machines = {
    overalls = { address = "10.90.0.1"; endpoint = "overallsPrimary"; peers = [ "dungarees" "salopettes" ]; };
    dungarees = { address = "10.90.0.2"; endpoint = "dungareesPrimary"; peers = [ "overalls" ]; };
    # Salopettes reaches only Overalls: Marshall delivers Susan pokes over fleet0.
    salopettes = { address = "10.90.0.3"; endpoint = "salopettesPrimary"; peers = [ "overalls" ]; };
  };
  name = config.networking.hostName;
  addresses = config.overalls.fleetAddresses;
  serviceCa = ./hosts/overalls/service-ca.crt;
  local = machines.${name};
  document = lib.findFirst (item: item.name == "${name}-fleet-network")
    (throw "Missing fleet network credential") inventory.${name}.credentials;
  encryptedFile = ../. + ("/" + document.path);
in {
  networking.wireguard.useNetworkd = false;
  # @cc [owner:ghuntley,label:security] production-fleet-peer-custody
  # Physical fleet peers MUST use distinct encrypted host credentials and pinned
  # public keys. Only Overalls may admit fleet API traffic; Salopettes admits
  # only the Susan relay and metrics, and peers only with Overalls. Guest prefixes MUST
  # remain protected, and transport failure MUST NOT select the browser API.
  overalls.fleetNetwork = {
    inherit (local) address;
    endpointAddressFile = addresses.files.${local.endpoint};
    endpointUnits = [ addresses.unit ];
    enable = true;
    privateKeyFile = "/run/overalls-secrets/fleet-network/private-key";
    secretUnits = [ "overalls-secrets-fleet-network.service" ];
    tcpPorts = if name == "overalls" then [ 4317 5443 5445 8443 9464 9467 ]
      else if name == "salopettes" then [ 443 9464 9467 ] else [ 9464 9467 ];
    peers = lib.genAttrs local.peers (peer: {
      inherit (machines.${peer}) address;
      endpointAddressFile = addresses.files.${machines.${peer}.endpoint};
      publicKey = publicKeys.${peer};
    });
  };
  services.overallsSecrets.bundles.fleet-network = {
    encryptedFile = "${encryptedFile}";
    outputs.private-key = { format = "raw"; secrets = [ "WIREGUARD_PRIVATE_KEY" ]; };
  };
  environment.etc."overalls/service-ca.crt".source = serviceCa;
  environment.etc."overalls/logstore-ca.crt".source = ./hosts/overalls/logstore-ca.crt;
  networking.hosts."10.90.0.1" = [ "logs.fleet.internal" ];
  services.lilly = {
    controlPlaneCAFile = "/etc/overalls/service-ca.crt";
    protectedCidrs = [ "10.90.0.0/24" ];
  };
  # @cc [owner:ghuntley,label:recovery;security] service-ca-consumers-follow-bundle
  # Consumers copy the service CA bundle at start (LoadCredential) or load it
  # once (HAProxy). A rotated bundle MUST restart or reload every enabled
  # consumer on activation; otherwise they keep verifying against the retired CA.
  systemd.services = lib.genAttrs (lib.attrNames (lib.filterAttrs (_: enabled: enabled) {
    lilly = config.services.lilly.enable;
    ziggy = config.services.ziggy.enable;
    audi = config.services.audi.enable;
    audi-dns = config.services.audiDns.enable;
    audi-private-certificate = config.services.audiPrivate.enable;
    overalls-logging = true;
  })) (_: {
    after = [ "wireguard-fleet0.service" ];
    wants = [ "wireguard-fleet0.service" ];
    restartTriggers = [ serviceCa ];
  }) // lib.optionalAttrs config.services.galileo.enable {
    galileo.restartTriggers = [ serviceCa ];
  } // lib.optionalAttrs config.services.porsche.enable {
    porsche.restartTriggers = [ serviceCa ];
  } // lib.optionalAttrs config.services.marshallProxy.enable {
    haproxy.reloadTriggers = [ serviceCa ];
  };
}

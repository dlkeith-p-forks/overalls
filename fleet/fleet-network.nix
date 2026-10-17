{ config, lib, ... }:
let
  inventory = (import ../nix/hosts/inventory.nix { inherit lib; }).hosts;
  publicKeys = builtins.fromJSON (builtins.readFile ./fleet-public-keys.json);
  machines = {
    overalls = { address = "10.90.0.1"; endpointAddress = "136.243.69.55"; };
    dungarees = { address = "10.90.0.2"; endpointAddress = "136.243.69.35"; };
  };
  name = config.networking.hostName;
  serviceCa = ./hosts/overalls/service-ca.crt;
  local = machines.${name};
  document = lib.findFirst (item: item.name == "${name}-fleet-network")
    (throw "Missing fleet network credential") inventory.${name}.credentials;
  encryptedFile = ../. + ("/" + document.path);
in {
  networking.wireguard.useNetworkd = false;
  # @cc [owner:ghuntley,label:security] production-fleet-peer-custody
  # Physical fleet peers MUST use distinct encrypted host credentials and pinned
  # public keys. Only Overalls may admit fleet API traffic. Guest prefixes MUST
  # remain protected, and transport failure MUST NOT select the browser API.
  overalls.fleetNetwork = local // {
    enable = true;
    privateKeyFile = "/run/overalls-secrets/fleet-network/private-key";
    secretUnits = [ "overalls-secrets-fleet-network.service" ];
    tcpPorts = if name == "overalls" then [ 4317 5443 5445 8443 9464 9467 ] else [ 9464 9467 ];
    peers = lib.mapAttrs (peer: settings: settings // { publicKey = publicKeys.${peer}; })
      (lib.filterAttrs (peer: _: peer != name) machines);
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
  systemd.services = lib.genAttrs [ "lilly" "ziggy" "audi" "audi-dns" "audi-private-certificate" "overalls-logging" ] (_: {
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

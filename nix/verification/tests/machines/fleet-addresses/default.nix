{ pkgs, module, packages }:
let
  # Hosts on VLAN 1 serve two listeners; VLAN 2 carries the runtime uplink.
  node = { nft, uplink }: { lib, ... }: {
    imports = [ module ];
    system.stateVersion = "26.05";
    virtualisation.vlans = [ 1 ] ++ lib.optional uplink 2;
    networking.useNetworkd = true;
    networking.nftables.enable = nft;
    services.openssh.enable = true;
    # The test framework would address eth2 statically; the uplink must not.
    networking.interfaces = lib.mkIf uplink { eth2.ipv4.addresses = lib.mkForce []; };
    overalls.fleetAddresses = {
      enable = true;
      encryptedFile = "/run/fleet-sealed/addresses.enc.json";
      names = {
        self = "SELF_IPV4";
        grant = "GRANT_IPV4";
      } // lib.optionalAttrs uplink {
        uplinkAddress = "UPLINK_IPV4";
        prefix = "UPLINK_PREFIX";
        gateway = "UPLINK_GATEWAY_IPV4";
      };
      uplink = lib.mkIf uplink {
        network = "40-eth2";
        addresses = [ "uplinkAddress" ];
        prefix = "prefix";
        gateway = "gateway";
      };
    };
    overalls.fleetFirewall = {
      enable = true;
      allowedHosts.grant = {
        addressFile = "/run/overalls-secrets/fleet-addresses/grant";
        addressUnit = "overalls-fleet-addresses.service";
        comment = "Fixture reviewed source";
      };
      publicServices.web = {
        addressFile = "/run/overalls-secrets/fleet-addresses/self";
        addressUnit = "overalls-fleet-addresses.service";
        tcpPorts = [ 80 ];
        comment = "Fixture public listener";
      };
    };
    # Listeners bind every address; only the firewall scopes them.
    systemd.services = lib.genAttrs [ "fixture-web-80" "fixture-web-8080" ] (name: {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server --bind 0.0.0.0 --directory /etc/fixture-web ${lib.removePrefix "fixture-web-" name}";
    });
    environment.etc."fixture-web/index.html".text = "fleet-address-fixture\n";
    environment.systemPackages = [ packages.secretTools.sops packages.secretTools.ssh-to-age pkgs.iptables pkgs.nftables ];
  };
in pkgs.testers.runNixOSTest {
  name = "overalls-fleet-addresses";
  nodes = {
    client = { lib, ... }: {
      system.stateVersion = "26.05";
      virtualisation.vlans = [ 1 2 ];
      networking.interfaces.eth2.ipv4.addresses = lib.mkForce [{ address = "10.20.0.1"; prefixLength = 24; }];
      environment.systemPackages = [ pkgs.curl ];
    };
    nft = node { nft = true; uplink = true; };
    legacy = node { nft = false; uplink = false; };
  };
  # @cc [owner:ghuntley,label:verification] fleet-addresses-machine-check
  # SOPS-delivered fleet addresses MUST open runtime source and destination
  # rules only after decryption and validation on both firewall backends,
  # refill after firewall reloads, follow rotation, close on a malformed
  # document, and apply the static uplink as a runtime networkd drop-in whose
  # recovery copy keeps the host addressed when the document is unreadable.
  testScript = builtins.readFile ./driver.py;
}

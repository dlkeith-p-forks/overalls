{ pkgs, module, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-public-address";
  nodes = {
    client = { ... }: {
      system.stateVersion = "26.05";
      networking.interfaces.eth1.ipv6.addresses = [{ address = "2001:db8:5::1"; prefixLength = 64; }];
      environment.systemPackages = [ pkgs.curl ];
    };
    host = { lib, ... }: {
      imports = [ module ];
      system.stateVersion = "26.05";
      networking.useNetworkd = true;
      networking.nftables.enable = false;
      services.openssh.enable = true;
      overalls.fleetFirewall = {
        enable = true;
        # The test VLAN is not a reviewed fleet source.
        allowedHosts = lib.mkForce {};
        publicServices.web = {
          addressFile = "/run/overalls-secrets/public-address/ipv4";
          addressUnit = "overalls-public-address.service";
          tcpPorts = [ 80 ];
          comment = "Public address fixture";
        };
      };
      overalls.publicAddress = {
        enable = true;
        encryptedFile = "/run/public-address-sealed/address.enc.json";
        network = "40-eth1";
      };
      # Listeners bind every address; only the firewall scopes them.
      systemd.services = lib.genAttrs [ "fixture-web-80" "fixture-web-8080" ] (name: {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server --bind 0.0.0.0 --directory /etc/fixture-web ${lib.removePrefix "fixture-web-" name}";
      });
      environment.etc."fixture-web/index.html".text = "public-address-fixture\n";
      environment.systemPackages = [ packages.secretTools.sops packages.secretTools.ssh-to-age pkgs.iptables ];
    };
  };
  # @cc [owner:ghuntley,label:verification] public-address-machine-check
  # The SOPS-delivered public address MUST open a destination-scoped listener
  # only after decryption and validation, survive firewall reloads, follow a
  # rotation, close on a malformed document and attach the IPv6 address only
  # through the runtime networkd drop-in.
  testScript = builtins.readFile ./driver.py;
}

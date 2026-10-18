{ pkgs, module }:
let
  inherit (pkgs) lib;
  evaluate = extra: (import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit pkgs;
    system = pkgs.stdenv.hostPlatform.system;
    modules = [ module {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
      services.audi = {
        enable = true;
        controlPlane = "https://control.example.test:5443";
        hostId = "11111111-1111-4111-8111-111111111111";
        credentialFile = "/run/private/gateway.token";
      };
    } extra ];
  }).config;
  valid = config: lib.all (item: item.assertion) config.assertions;
  ready = evaluate { services.openssh = { enable = true; ports = [ 2222 ]; }; };
  absent = evaluate {};
  console = evaluate { services.audi.administrativeAccess = "console"; };
  consoleWithSSH = evaluate {
    services.audi.administrativeAccess = "console";
    services.openssh = { enable = true; ports = [ 2222 ]; };
  };
  overlapping = evaluate { services.openssh.enable = true; };
  collision = evaluate {
    services.openssh = { enable = true; ports = [ 2222 ]; };
    services.porsche = {
      enable = true;
      controlPlane = "https://control.example.test";
      publicOrigin = "https://control.example.test";
      credentialFile = "/run/private/porsche.token";
    };
  };
  colocated = audiAddress: porscheAddress: nftables: evaluate {
    networking.nftables.enable = nftables;
    services.openssh = { enable = true; ports = [ 2222 ]; };
    services.audi = { bindAddress = audiAddress; openFirewall = true; };
    services.porsche = {
      enable = true; bindAddress = porscheAddress; openFirewall = true;
      controlPlane = "https://control.example.test";
      publicOrigin = "https://control.example.test";
      credentialFile = "/run/private/porsche.token";
    };
  };
  separate = colocated "136.243.69.37" "136.243.69.55" true;
  separateIptables = colocated "136.243.69.37" "136.243.69.55" false;
  ipv4 = (import ../../../domains/system/types.nix { inherit lib; }).ipv4;
  custom = evaluate { services.audi.port = 2200; services.openssh.enable = true; };
  tlsConfig = extra: evaluate {
    services.audi = {
      port = 2200;
      openFirewall = true;
      tls = {
        enable = true;
        zone = "apps.example";
        browserOrigin = "https://control.example.test";
      } // extra;
    };
  };
  tls = tlsConfig {};
  nonEditorSingleLabel = evaluate {
    services.audi = {
      port = 2200;
      editorPackage = null;
      tls = { enable = true; zone = "apps"; browserOrigin = "https://control.example.test"; };
    };
  };
  connector = host: evaluate {
    networking.hostId = "12345678";
    services.audi.port = 2200;
    services.lilly = {
      enable = true;
      ingress.enable = true;
      hostId = host;
      controlPlane = "https://control.example.test";
      egressInterface = "eth0";
      guestCpuCores = 1;
      guestMemoryMiB = 256;
      pools = [{
        id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
        path = "/pool";
        filesystem_id = "zfs:123:456";
        storage = { dataset = "tank/lilly"; dataset_guid = "456"; zpool_guid = "123"; };
      }];
    };
  };
  relayConfig = extra: evaluate {
    services.audi = { port = 2200; relay = { enable = true; } // extra; };
    overalls.fleetNetwork = {
      enable = true;
      address = "10.90.0.1";
      endpointAddress = "192.0.2.1";
      privateKeyFile = "/run/private/fleet.key";
      peers.worker = {
        address = "10.90.0.2";
        endpointAddress = "192.0.2.2";
        publicKey = lib.concatStrings (lib.replicate 43 "A") + "=";
      };
    };
  };
  relay = relayConfig {};
in
# @cc [owner:ghuntley,label:verification] audi-administrative-port-precondition
# Physical-host defaults MUST require administrative OpenSSH on 2222 for port
# 22 management. Explicit console-only mode MUST instead forbid OpenSSH. All
# modes MUST reject listener collisions. Port changes alone do not prove that
# an operator can authenticate; staged deployment acceptance remains separate.

# @cc [owner:ghuntley,label:verification;security] audi-relay-fleet-firewall-scope
# Relay enablement MUST use the local keyed fleet address and declared peers,
# expose its port only through fleet rules, and reject arbitrary address/peer overrides.
assert valid relay;
assert relay.services.audi.relay.address == "10.90.0.1";
assert relay.services.audi.relay.peers == [ "10.90.0.2" ];
assert builtins.elem 9445 relay.overalls.fleetNetwork.tcpPorts;
assert !(builtins.elem 9445 relay.networking.firewall.allowedTCPPorts);
assert !valid (relayConfig { address = "192.0.2.1"; });
assert !valid (relayConfig { peers = [ "10.90.0.3" ]; });
assert valid ready;
assert valid separate;
assert valid separateIptables;
assert !valid (colocated "136.243.69.37" "136.243.69.37" true);
assert !valid (colocated "0.0.0.0" "136.243.69.55" true);
assert !valid (colocated "136.243.69.37" "0.0.0.0" true);
assert !(builtins.elem 22 separate.networking.firewall.allowedTCPPorts);
assert lib.hasInfix "ip daddr 136.243.69.37 tcp dport 22 accept" separate.networking.firewall.extraInputRules;
assert lib.hasInfix "ip daddr 136.243.69.55 tcp dport 22 accept" separate.networking.firewall.extraInputRules;
assert lib.hasInfix "-d 136.243.69.37 -p tcp --dport 22" separateIptables.networking.firewall.extraCommands;
assert ipv4.check "136.243.69.37";
assert lib.all (value: !ipv4.check value) [ "::" "::1" "::ffff:192.0.2.1" "127.1" "256.1.1.1" "01.2.3.4" ];
assert !valid absent;
assert valid console;
assert !valid consoleWithSSH;
assert !valid overlapping;
assert valid custom;
assert valid tls;
assert !valid (tlsConfig { zone = "apps"; });
assert valid nonEditorSingleLabel;
assert !valid (tlsConfig { browserOrigin = "https://control.example.test:5443"; });
assert !valid (tlsConfig { httpsPort = 2200; });
assert builtins.elem 80 tls.networking.firewall.allowedTCPPorts;
assert builtins.elem 443 tls.networking.firewall.allowedTCPPorts;
assert builtins.length tls.systemd.services.audi.serviceConfig.LoadCredential == 3;
assert !valid collision;
assert valid (connector "11111111-1111-4111-8111-111111111111");
assert !valid (connector "22222222-2222-4222-8222-222222222222");
assert ready.systemd.services.audi.serviceConfig.User == "audi";
assert ready.systemd.services.audi.serviceConfig.RestrictAddressFamilies == [ "AF_UNIX" "AF_INET" "AF_NETLINK" ];
assert ready.systemd.services.audi.serviceConfig.CapabilityBoundingSet == [ "CAP_NET_BIND_SERVICE" ];
assert ready.systemd.services.audi.serviceConfig.AmbientCapabilities == [ "CAP_NET_BIND_SERVICE" ];
assert ready.systemd.services.audi.serviceConfig.LoadCredential == [
  "gateway.token:/run/private/gateway.token"
  "ca.pem:${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
];
pkgs.runCommand "audi-configuration-check" {} ''touch "$out"''

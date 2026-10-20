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
  separate = colocated "198.51.100.37" "198.51.100.55" true;
  separateIptables = colocated "198.51.100.37" "198.51.100.55" false;
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
  windowsEditor = pkgs.runCommand "windows-editor-configuration-fixture" {
    passthru = { editorProtocol = 1; sourceCommit = lib.concatStrings (lib.replicate 40 "a"); releaseId = lib.concatStrings (lib.replicate 64 "d"); };
  } ''touch "$out"'';
  dualEditors = evaluate {
    services.audi = {
      port = 2200;
      editorPackages = {
        linux-x64 = tls.services.audi.editorPackages.linux-x64;
        win32-x64 = windowsEditor;
      };
      tls = { enable = true; zone = "apps.example"; browserOrigin = "https://control.example.test"; };
    };
  };
  nonEditorSingleLabel = evaluate {
    services.audi = {
      port = 2200;
      editorPackages = {};
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
  audiFile = "/run/overalls-secrets/fleet-addresses/service";
  porscheFile = "/run/overalls-secrets/fleet-addresses/primary";
  addressUnit = "overalls-fleet-addresses.service";
  porscheBase = {
    enable = true;
    controlPlane = "https://control.example.test";
    publicOrigin = "https://control.example.test";
    credentialFile = "/run/private/porsche.token";
  };
  runtimeAudi = { bindAddressFile = audiFile; bindAddressUnit = addressUnit; };
  runtimePorsche = { bindAddressFile = porscheFile; bindAddressUnit = addressUnit; };
  paired = audi: porsche: evaluate {
    services.openssh = { enable = true; ports = [ 2222 ]; };
    services.audi = audi;
    services.porsche = porscheBase // porsche;
  };
  bothRuntime = paired runtimeAudi runtimePorsche;
  audiRuntimeOnly = paired runtimeAudi { bindAddress = "198.51.100.55"; };
  porscheRuntimeOnly = paired { bindAddress = "198.51.100.37"; } runtimePorsche;
  audiUnit = config: config.systemd.services.audi;
  dns = extra: evaluate {
    services.audi.port = 2200;
    services.audiDns = {
      enable = true;
      controlPlane = "https://control.example.test:5443";
      credentialFile = "/run/private/dns.token";
      zone = "apps.example";
      nameservers = [ "ns1.example" "ns2.example" ];
      mailbox = "hostmaster.example";
    } // extra;
  };
  runtimeDns = dns { bindAddressFile = audiFile; bindAddressUnit = addressUnit; };
  dnsUnit = runtimeDns.systemd.services.audi-dns;
  bind = import ../../../domains/system/runtime-bind.nix { inherit lib pkgs; };
  # Executes the shared validation against accepted and refused inputs.
  validation = pkgs.runCommand "runtime-bind-validation-check" { nativeBuildInputs = [ pkgs.bash ]; } ''
    cat > check.sh <<'EOF'
    set -u
    ${bind.validate}
    accept() { printf '%s' "$1" > value; result="$(overalls_bind_address value)" || { echo "refused $1"; exit 1; }; [ "$result" = "$2" ] || { echo "mangled $1"; exit 1; }; }
    refuse() { printf '%s' "$1" > value; if overalls_bind_address value >/dev/null 2>err; then echo "accepted $1"; exit 1; fi; [ -z "$1" ] || ! grep -F -- "$1" err >/dev/null || { echo "echoed $1"; exit 1; }; }
    accept "198.51.100.37" "198.51.100.37"
    accept $'203.0.113.9\n' "203.0.113.9"
    refuse "0.0.0.0"
    refuse "256.1.1.1"
    refuse "01.2.3.4"
    refuse "192.0.2"
    refuse "192.0.2.1 192.0.2.2"
    refuse "::1"
    refuse "192.0.2.1;id"
    refuse ""
    EOF
    bash check.sh
    touch "$out"
  '';
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
assert !valid (colocated "198.51.100.37" "198.51.100.37" true);
assert !valid (colocated "0.0.0.0" "198.51.100.55" true);
assert !valid (colocated "198.51.100.37" "0.0.0.0" true);
assert !(builtins.elem 22 separate.networking.firewall.allowedTCPPorts);
assert lib.hasInfix "ip daddr 198.51.100.37 tcp dport 22 accept" separate.networking.firewall.extraInputRules;
assert lib.hasInfix "ip daddr 198.51.100.55 tcp dport 22 accept" separate.networking.firewall.extraInputRules;
assert lib.hasInfix "-d 198.51.100.37 -p tcp --dport 22" separateIptables.networking.firewall.extraCommands;
assert ipv4.check "198.51.100.37";
assert lib.all (value: !ipv4.check value) [ "::" "::1" "::ffff:192.0.2.1" "127.1" "256.1.1.1" "01.2.3.4" ];
assert !valid absent;
assert valid console;
assert !valid consoleWithSSH;
assert !valid overlapping;
assert valid custom;
assert valid tls;
assert valid dualEditors;
assert builtins.attrNames dualEditors.services.audi.editorPackages == [ "linux-x64" "win32-x64" ];
assert !(builtins.tryEval (builtins.deepSeq (evaluate {
  services.audi = { port = 2200; editorPackages.windows-x64 = windowsEditor; };
}).services.audi.editorPackages true)).success;
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
assert lib.hasPrefix "/nix/store/" ready.systemd.services.audi.environment.AUDI_CONFIG_FILE;

# @cc [owner:ghuntley,label:verification;security] audi-runtime-bind-configuration-check
# Runtime Audi, Audi DNS and colocated Porsche binds MUST follow their
# publishing unit, arrive only as credentials, render private runtime
# configuration, keep the Audi/Porsche address separation as a start-time
# refusal and still reject static wildcards on a shared port.
assert valid bothRuntime;
assert (audiUnit bothRuntime).environment.AUDI_CONFIG_FILE == "/run/audi/config.json";
assert builtins.elem addressUnit (audiUnit bothRuntime).requires;
assert lib.all (credential: builtins.elem credential (audiUnit bothRuntime).serviceConfig.LoadCredential) [
  "bind-address:${audiFile}" "porsche-bind-address:${porscheFile}"
];
assert lib.all (fragment: lib.hasInfix fragment (audiUnit bothRuntime).preStart) [
  ''porsche_address="$(overalls_bind_address "$CREDENTIALS_DIRECTORY/porsche-bind-address")"''
  ''if [ "$bind_address" = "$porsche_address" ]; then''
  "/run/audi/config.json.new"
];
assert valid audiRuntimeOnly;
assert lib.hasInfix "porsche_address=${lib.escapeShellArg "198.51.100.55"}" (audiUnit audiRuntimeOnly).preStart;
assert !(builtins.elem "porsche-bind-address:${porscheFile}" (audiUnit audiRuntimeOnly).serviceConfig.LoadCredential);
assert valid porscheRuntimeOnly;
assert lib.hasInfix "bind_address=${lib.escapeShellArg "198.51.100.37"}" (audiUnit porscheRuntimeOnly).preStart;
assert lib.hasPrefix "/nix/store/" (audiUnit porscheRuntimeOnly).environment.AUDI_CONFIG_FILE;
assert builtins.elem addressUnit (audiUnit porscheRuntimeOnly).after;
assert !valid (paired runtimeAudi {});
assert !valid (paired { bindAddress = "0.0.0.0"; } runtimePorsche);
assert !valid (paired (runtimeAudi // { openFirewall = true; }) runtimePorsche);
assert !valid (paired (runtimeAudi // { bindAddress = "198.51.100.37"; }) runtimePorsche);
assert !valid (paired (runtimeAudi // { bindAddressUnit = null; }) runtimePorsche);
# Distinct ports need no runtime comparison.
assert !(lib.hasInfix "porsche_address" (audiUnit (paired (runtimeAudi // { port = 2200; }) runtimePorsche)).preStart);
assert valid runtimeDns;
assert runtimeDns.services.audiDns.bindAddress == null;
assert dnsUnit.environment.AUDI_CONFIG_FILE == "/run/audi-dns/config.json";
assert builtins.elem addressUnit dnsUnit.after && builtins.elem addressUnit dnsUnit.requires;
assert builtins.elem "bind-address:${audiFile}" dnsUnit.serviceConfig.LoadCredential;
assert lib.hasInfix "/run/audi-dns/config.json.new" dnsUnit.script;
assert valid (dns {});
assert lib.hasPrefix "/nix/store/" (dns {}).systemd.services.audi-dns.environment.AUDI_CONFIG_FILE;
assert !valid (dns { bindAddressFile = audiFile; });
assert !valid (dns { bindAddressFile = audiFile; bindAddressUnit = addressUnit; openFirewall = true; });
pkgs.runCommand "audi-configuration-check" { inherit validation; } ''touch "$out"''

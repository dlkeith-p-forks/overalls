{ pkgs }:
let
  keys = pkgs.runCommand "disposable-fleet-wireguard-keys" { nativeBuildInputs = [ pkgs.wireguard-tools ]; } ''
    mkdir -p "$out"
    for name in first second; do
      wg genkey > "$out/$name.key"
      wg pubkey < "$out/$name.key" > "$out/$name.pub"
    done
  '';
  host = name: other: slot: peerSlot: nft: runtime: { config, nodes, lib, ... }: {
    imports = [ ../../../../domains/system/fleet-network.nix ];
    system.stateVersion = "26.05";
    virtualisation.memorySize = 512;
    virtualisation.cores = 1;
    virtualisation.qemu.forceAccel = pkgs.lib.mkForce true;
    networking.nftables.enable = nft;
    networking.dhcpcd.denyInterfaces = [ "probe-*" ];
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    environment.systemPackages = [ pkgs.curl pkgs.iproute2 pkgs.wireguard-tools pkgs.python3 ];
    overalls.fleetNetwork = {
      enable = true;
      address = "10.90.0.${toString slot}";
      # The runtime host learns both physical endpoints from files, as fleet
      # hosts do from the SOPS-delivered fleet addresses.
      endpointAddress = lib.mkIf (!runtime) config.networking.primaryIPAddress;
      endpointAddressFile = lib.mkIf runtime "/run/fleet-endpoints/self";
      endpointUnits = lib.optional runtime "fleet-fixture-endpoints.service";
      privateKeyFile = "/run/fleet-key/private";
      secretUnits = [ "fleet-fixture-key.service" ];
      tcpPorts = [ 5443 ];
      peers.${other} = {
        address = "10.90.0.${toString peerSlot}";
        endpointAddress = lib.mkIf (!runtime) nodes.${other}.networking.primaryIPAddress;
        endpointAddressFile = lib.mkIf runtime "/run/fleet-endpoints/peer";
        publicKey = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile "${keys}/${other}.pub");
      };
    };
    # @cc [owner:ghuntley,label:verification] disposable-wireguard-custody
    # These generated store keys MUST be used only in this isolated test. The
    # real module MUST consume a runtime private key and retain its startup gate.
    systemd.services.fleet-fixture-key = {
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; RuntimeDirectory = "fleet-key"; RuntimeDirectoryMode = "0700"; };
      script = "install -m 0600 ${keys}/${name}.key /run/fleet-key/private";
    };
    # Publishes the endpoints only once the test releases them, standing in for
    # the fleet address validator so the closed state is observable.
    systemd.services.fleet-fixture-endpoints = lib.mkIf runtime {
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; RuntimeDirectory = "fleet-endpoints"; RuntimeDirectoryPreserve = true; };
      script = ''
        test -e /run/fleet-endpoints-release
        printf '%s\n' ${config.networking.primaryIPAddress} > /run/fleet-endpoints/self
        cat /run/fleet-endpoints-release > /run/fleet-endpoints/peer
      '';
    };
    systemd.services.fleet-fixture-http = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 5443 --bind 0.0.0.0 --directory /etc";
    };
    systemd.services.fleet-fixture-denied = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 5444 --bind 0.0.0.0 --directory /etc";
    };
  };
in pkgs.testers.runNixOSTest {
  name = "overalls-fleet-network";
  nodes.first = host "first" "second" 1 2 true true;
  nodes.second = host "second" "first" 2 1 false false;
  testScript = ''
    start_all()
    pairs = [(first, second, "10.90.0.2"), (second, first, "10.90.0.1")]
    for machine in [first, second]:
        machine.wait_for_unit("wireguard-fleet0.service")
        machine.wait_for_unit("fleet-fixture-http.service")
        machine.wait_for_unit("fleet-fixture-denied.service")
        machine.succeed("test $(stat -c %a /run/fleet-key/private) = 600")
        machine.succeed("test -z \"$(ip -6 address show scope global)\"")

    with subtest("runtime endpoints stay closed until published, then apply"):
        peer_address = second.succeed("ip -4 -o address show dev eth1 | awk '{print $4}' | cut -d/ -f1").strip()
        first.fail("systemctl is-active overalls-fleet-endpoint-second.service")
        first.fail("systemctl is-active overalls-runtime-firewall.service")
        first.succeed("test -z \"$(wg show fleet0 endpoints | awk '$2 != \"(none)\"')\"")
        second.fail("curl -4 --fail --silent --max-time 3 http://10.90.0.1:5443/hostname")
        first.succeed("printf '%s\\n' not-an-address > /run/fleet-endpoints-release")
        first.fail("systemctl start overalls-fleet-endpoint-second.service")
        first.fail("systemctl start overalls-runtime-firewall.service")
        first.succeed(f"printf '%s\\n' {peer_address} > /run/fleet-endpoints-release")
        first.succeed("systemctl restart fleet-fixture-endpoints.service")
        first.succeed("systemctl start overalls-fleet-endpoint-second.service")
        first.succeed(f"wg show fleet0 endpoints | grep -F '{peer_address}:51820'")
        first.succeed("systemctl start overalls-runtime-firewall.service")
        first.succeed(f"nft list chain inet nixos-fw overalls-runtime | grep -F 'ip saddr {peer_address}' | grep -F 'udp dport 51820'")

    with subtest("authenticated IPv4 tunnel on both firewall backends"):
        for source, target, address in pairs:
            source.wait_until_succeeds(f"curl -4 --fail --silent --max-time 3 http://{address}:5443/hostname", timeout=60)
            target.succeed("curl -4 --fail --silent http://127.0.0.1:5444/hostname")
            source.fail(f"curl -4 --fail --silent --max-time 3 http://{address}:5444/hostname")
            source.fail(f"curl -4 --fail --silent --max-time 3 http://{target.name}:5443/hostname")

    with subtest("authenticated peers cannot forward into another network"):
        for machine in [first, second]:
            machine.succeed("ip netns add fleet-probe")
            machine.succeed("ip link add probe-host type veth peer name probe-guest netns fleet-probe")
            machine.succeed("ip address add 10.91.0.1/30 dev probe-host; ip link set probe-host up")
            machine.succeed("ip netns exec fleet-probe ip address add 10.91.0.2/30 dev probe-guest")
            machine.succeed("ip netns exec fleet-probe ip link set probe-guest up")
            machine.succeed("ip netns exec fleet-probe ip route add default via 10.91.0.1")
            machine.succeed("systemd-run --unit=fleet-forward-probe ip netns exec fleet-probe ${pkgs.python3}/bin/python3 -m http.server 5443 --bind 10.91.0.2 --directory /etc")
            machine.wait_until_succeeds("curl -4 --fail --silent --max-time 3 http://10.91.0.2:5443/hostname", timeout=30)
        for source, target, address in pairs:
            source.succeed(f"wg set fleet0 peer $(wg show fleet0 peers) allowed-ips {address}/32,10.91.0.2/32")
            source.succeed("ip route add 10.91.0.2/32 dev fleet0")
            source.fail("curl -4 --fail --silent --max-time 3 http://10.91.0.2:5443/hostname")
            if target == first:
                target.succeed("nft list chain inet overalls-fleet forward | grep -E 'iifname.*fleet0.*counter packets [1-9][0-9]*.*drop'")
            else:
                target.succeed("iptables -nvx -L FORWARD | awk '$3 == \"DROP\" && $6 == \"fleet0\" && $1 > 0 {found=1} END {exit !found}'")
            source.succeed("ip route del 10.91.0.2/32 dev fleet0")
            source.succeed(f"wg set fleet0 peer $(wg show fleet0 peers) allowed-ips {address}/32")

    with subtest("revoked peer key loses access"):
        second.succeed("wg show fleet0 peers > /run/fleet-peer-public")
        second.succeed("wg set fleet0 peer $(cat /run/fleet-peer-public) remove")
        first.fail("curl -4 --fail --silent --max-time 4 http://10.90.0.2:5443/hostname")
  '';
}

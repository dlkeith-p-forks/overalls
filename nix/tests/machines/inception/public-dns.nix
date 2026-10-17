{ packages, address }:
{ lib, pkgs, ... }:
{
  imports = [ (import ../../../modules/audi-dns.nix { inherit packages; }) ];
  system.stateVersion = "26.05";
  networking.enableIPv6 = false;
  networking.interfaces.eth1.ipv4.addresses = [ { inherit address; prefixLength = 24; } ];
  networking.hosts."11.0.0.1" = [ "control.example.test" ];
  virtualisation.memorySize = 1024;
  virtualisation.cores = 2;
  virtualisation.qemu.forceAccel = lib.mkForce true;
  environment.systemPackages = [ pkgs.python3 ];
  environment.etc."public-dns-probe.py".source = ./dns_probe.py;
  environment.etc."public-dns-probe.json".text = builtins.toJSON {
    zone = "apps.inception.test";
    nameservers = [ "ns1.inception.test" "ns2.inception.test" ];
  };
  services.audiDns = {
    enable = true;
    openFirewall = true;
    bindAddress = address;
    controlPlane = "https://control.example.test:5443";
    credentialFile = "/run/inception-dns/dns.token";
    caFile = "/run/inception-dns/control-ca.pem";
    zone = "apps.inception.test";
    nameservers = [ "ns1.inception.test" "ns2.inception.test" ];
    mailbox = "hostmaster.inception.test";
  };
  # Each machine receives a different enrolled DNS token. The driver starts
  # the real service only after installing that token and public control trust.
  # No synthetic snapshot or static app record is inserted here.
  systemd.services.audi-dns.wantedBy = lib.mkForce [];
}

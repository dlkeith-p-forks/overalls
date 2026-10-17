{ config, lib, pkgs, ... }:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.services.marshallProxy.acme;
  http = cfg.http01;
  proxy = config.services.marshallProxy;
  enabled = cfg.enable && cfg.challengeType == "http-01";
  ipType = (import ../types.nix { inherit lib; }).ipv4;
  isLoopback = address: lib.hasPrefix "127." address;
  isPrivate = address:
    lib.hasPrefix "10." address || lib.hasPrefix "192.168." address
    || (lib.hasPrefix "172." address && (let second = lib.toInt (builtins.elemAt (lib.splitString "." address) 1); in second >= 16 && second <= 31));
  addresses = map (peer: peer.address) http.peers;
  port = toString http.port;
  python = pkgs.python3.withPackages (p: [ p.aiohttp ]);
  lookupConfig = pkgs.writeText "marshall-acme-http.json" (builtins.toJSON {
    hostname = lib.toLower proxy.publicHost;
    local = { address = http.bindAddress; inherit (http) port; };
    peers = http.peers;
    socket = "/run/marshall-acme-http/lookup.sock";
  });
  httpConfig = pkgs.writeText "marshall-acme-http.cfg" ''
    global
      log stdout format raw local0
      maxconn 64
    defaults
      mode http
      log global
      timeout connect 1s
      timeout client 5s
      timeout server 4s
      log-format '{"event":"acme.http_request","status":%ST,"duration_ms":%Tt}'
    frontend http
      bind ${proxy.bindAddress}:80
      acl public_host hdr(host),lower -m str ${lib.toLower proxy.publicHost} ${lib.toLower proxy.publicHost}:80
      acl challenge path_beg /.well-known/acme-challenge/
      http-request deny deny_status 421 unless public_host
      http-request deny deny_status 405 if challenge !METH_GET
      http-request redirect code 308 prefix https://${lib.toLower proxy.publicHost}${lib.optionalString (proxy.port != 443) ":${toString proxy.port}"} unless challenge
      default_backend lookup
    backend lookup
      server local /run/marshall-acme-http/lookup.sock
  '';
  hardening = {
    User = "marshall-acme-http";
    Group = "marshall-acme-http";
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
    UMask = "0077";
    Restart = "on-failure";
    RestartSec = "2s";
  };
in
{
  options.services.marshallProxy.acme.http01 = {
    bindAddress = mkOption {
      type = ipType; default = "127.0.0.1";
      description = "Local Lego responder IP; use a stable private address when configuring peers.";
    };
    port = mkOption { type = types.ints.between 1024 65535; default = 9080; description = "Private Lego responder port, never the public validation port."; };
    publicIngress = mkOption {
      type = types.bool; default = false;
      description = "Admit port 80 on the proxy address from any source through the fleet perimeter (ADR-0181), so the public CA can reach HTTP-01 challenges. The listener serves only challenges and HTTPS redirects.";
    };
    peers = mkOption {
      default = [];
      description = "Other HTTP-01 issuers for the same hostname on a trusted private network. Configure every frontend with every other issuer.";
      type = types.listOf (types.submodule {
        options = {
          address = mkOption { type = ipType; description = "Stable private peer IP (not its public round-robin hostname)."; };
          port = mkOption { type = types.ints.between 1024 65535; default = 9080; description = "Peer's Lego responder port."; };
        };
      });
    };
  };

  # @cc [owner:ghuntley,label:security] http-validation-private-peers
  # Remote responders MUST be explicit, unique private IPv4 addresses.
  # Firewall management MUST allow their source IPs only, never open the responder
  # port globally. HTTP and lookup processes MUST NOT receive certificate keys.
  config = mkIf enabled {
    assertions = [
      { assertion = isLoopback http.bindAddress || isPrivate http.bindAddress; message = "HTTP-01 responder must bind a loopback or private IP, never a wildcard or public address."; }
      { assertion = http.peers == [] || isPrivate http.bindAddress; message = "HTTP-01 peers require a stable private local bindAddress."; }
      { assertion = lib.all (peer: isPrivate peer.address) http.peers; message = "HTTP-01 peers require private IPv4 addresses."; }
      { assertion = lib.unique addresses == addresses && !(builtins.elem http.bindAddress addresses); message = "HTTP-01 peers must not contain duplicate or self addresses."; }
      { assertion = proxy.port != 80 && proxy.port != http.port && lib.all
          (instance: instance.port != 80 && instance.port != http.port && instance.fleetPort != 80 && instance.fleetPort != http.port)
          (lib.optionals config.services.marshall.enable (builtins.attrValues config.services.marshall.instances));
        message = "HTTP-01 public and responder ports must not collide with HTTPS or Marshall listeners."; }
    ];
    users.users.marshall-acme-http = { isSystemUser = true; group = "marshall-acme-http"; };
    users.groups.marshall-acme-http = {};
    networking.firewall = mkIf proxy.openFirewall (lib.mkMerge [
      (import ../listener-firewall.nix {
        inherit lib config; address = proxy.bindAddress; tcpPorts = [ 80 ];
      })
      {
      extraInputRules = mkIf config.networking.nftables.enable (lib.concatMapStringsSep "\n" (peer:
        "ip saddr ${peer.address} ip daddr ${http.bindAddress} tcp dport ${port} accept") http.peers);
      extraCommands = mkIf (!config.networking.nftables.enable) (lib.concatMapStringsSep "\n" (peer:
        "iptables -w -A nixos-fw -s ${peer.address} -d ${http.bindAddress} -p tcp --dport ${port} -j nixos-fw-accept") http.peers);
      }
    ]);

    # @cc [owner:ghuntley,label:recovery] http-validation-independent-bootstrap
    # HTTP routing MUST start without a certificate or the HTTPS proxy. Issuance
    # MUST wait for HTTP routing, with no reverse dependency on the issuer.
    systemd.services.marshall-acme-lookup = {
      description = "Bounded HTTP-01 lookup across configured issuers";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = hardening // {
        RuntimeDirectory = "marshall-acme-http";
        RuntimeDirectoryMode = "0700";
        ExecStart = "${python}/bin/python ${./lookup.py} ${lookupConfig}";
        CapabilityBoundingSet = "";
      };
    };
    systemd.services.marshall-acme-http = {
      description = "HTTP-01 ingress and permanent HTTPS redirects";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "marshall-acme-lookup.service" ];
      wants = [ "marshall-acme-lookup.service" ];
      serviceConfig = hardening // {
        Type = "notify";
        ExecStartPre = "${lib.getExe config.services.haproxy.package} -c -f ${httpConfig}";
        ExecStart = "${lib.getExe config.services.haproxy.package} -Ws -f ${httpConfig}";
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        KillMode = "mixed";
      };
    };
    # @cc [owner:ghuntley,label:security;deployment] http-validation-public-ingress
    # Public HTTP-01 MUST be an explicit opt-in that admits only TCP 80 on the
    # proxy's explicit address, sharing the proxy's single perimeter entry.
    overalls.fleetFirewall.publicServices.marshall-proxy = mkIf (http.publicIngress && config.overalls.fleetFirewall.enable) {
      address = proxy.bindAddress;
      tcpPorts = [ 80 ];
      comment = "Marshall proxy public listeners";
    };
    systemd.services."acme-order-renew-${proxy.publicHost}" = {
      after = [ "marshall-acme-http.service" ];
      requires = [ "marshall-acme-http.service" ];
    };
  };
}

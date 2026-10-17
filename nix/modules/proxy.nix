{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.marshallProxy;
  localTypes = import ./types.nix { inherit lib; };
  names = builtins.attrNames cfg.backends;
in
{
  options.services.marshallProxy = {
    enable = mkEnableOption "HAProxy HTTPS termination with verified Marshall backends";
    publicHost = mkOption {
      type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9.-]*";
      description = "Public DNS hostname accepted by the proxy.";
    };
    bindAddress = mkOption {
      type = localTypes.ipv4;
      default = "0.0.0.0";
      description = "Literal public listener address.";
    };
    port = mkOption {
      type = types.port;
      default = 443;
      description = "Public HTTPS port.";
    };
    certificateFile = mkOption {
      type = localTypes.privatePath;
      description = "Atomically published PEM key and full certificate chain, readable by the haproxy group.";
    };
    backendCAFile = mkOption {
      type = localTypes.absolutePath;
      default = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      description = "CA bundle authenticating Marshall backend certificates.";
    };
    secretUnits = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service");
      default = [];
      description = "Required services publishing runtime TLS files before proxy startup.";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open the public HTTPS port.";
    };
    backends = mkOption {
      default = {};
      description = "Marshall TLS endpoints, keyed by backend identity.";
      type = types.attrsOf (types.submodule {
        options = {
          address = mkOption {
            type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9.-]*";
            description = "Backend IPv4 address or hostname.";
          };
          port = mkOption { type = types.port; default = 4443; description = "Backend HTTPS port."; };
          serverName = mkOption {
            type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9.-]*";
            description = "Required certificate hostname and TLS SNI for traffic and health checks.";
          };
        };
      });
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      { assertion = names != [] && builtins.length names <= 100;
        message = "Marshall proxy requires 1..100 explicitly configured TLS backends."; }
      { assertion = lib.all (name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}" name != null) names;
        message = "Marshall proxy backend names must be valid identifiers."; }
      { assertion = !config.services.marshall.enable || lib.all (instance: instance.port != cfg.port && instance.fleetPort != cfg.port)
          (builtins.attrValues config.services.marshall.instances);
        message = "Marshall proxy and local backend ports must be distinct."; }
    ];
    networking.firewall = mkIf cfg.openFirewall (import ./listener-firewall.nix {
      inherit lib config; address = cfg.bindAddress; tcpPorts = [ cfg.port ];
    });
    services.haproxy.enable = true;

    # @cc [owner:ghuntley,label:security] proxy-verifies-both-tls-paths
    # Traffic and readiness probes MUST verify backend CA and hostname. Only
    # HTTP 200 from /health/ready may admit a backend; PROXY protocol is unused.
    services.haproxy.config = ''
      global
        log stdout format raw local0
        ssl-default-bind-options ssl-min-ver TLSv1.2
        ssl-default-server-options ssl-min-ver TLSv1.2

      defaults
        mode http
        log global
        timeout connect 5s
        timeout client 60s
        timeout server 60s
        timeout tunnel 1h
        timeout check 3s
        log-format '{"event":"proxy_request","status":%ST,"bytes":%B,"duration_ms":%Tt,"request_id":"%ID","backend":"%b","server":"%s","termination":"%tsc","queue_ms":%Tw,"connect_ms":%Tc,"response_ms":%Tr}'

      # @cc [owner:ghuntley,label:security;capacity] proxy-local-slo-counters
      # Only the loopback collector may scrape bounded HAProxy response-class
      # counters. Public clients never reach the exporter frontend.
      frontend marshall_slo_metrics
        bind 127.0.0.1:8405
        mode http
        http-request use-service prometheus-exporter if { path /metrics }
        http-request deny

      frontend marshall_public
        unique-id-format %[uuid()]
        http-request set-header X-Request-ID %[unique-id]
        bind ${cfg.bindAddress}:${toString cfg.port} ssl crt ${cfg.certificateFile} alpn h2,http/1.1
        acl public_host hdr(host),lower -m str ${lib.toLower cfg.publicHost} ${lib.toLower cfg.publicHost}:${toString cfg.port}
        http-request deny deny_status 421 unless public_host
        http-request del-header Forwarded
        http-request set-header X-Forwarded-Proto https
        http-request set-header X-Forwarded-Host ${cfg.publicHost}
        http-request set-header X-Forwarded-For %[src]
        default_backend marshall_nodes

      backend marshall_nodes
        balance roundrobin
        option httpchk
        http-check send meth GET uri /health/ready ver HTTP/1.1 hdr Host ${cfg.publicHost}
        http-check expect status 200
        default-server inter 1s fall 2 rise 2
        ${lib.concatStringsSep "\n  " (lib.mapAttrsToList (name: backend:
          "server ${name} ${backend.address}:${toString backend.port} resolve-prefer ipv4 ssl verify required verifyhost ${backend.serverName} sni str(${backend.serverName}) check check-ssl check-sni ${backend.serverName} ca-file ${cfg.backendCAFile}") cfg.backends)}
    '';

    # @cc [owner:ghuntley,label:security] proxy-reload-and-diagnostics
    # TLS files MUST remain outside the store and be reread on validated reload.
    # Request logs MUST exclude URLs, headers, credentials and terminal payloads.
    systemd.services.haproxy = {
      after = cfg.secretUnits;
      requires = cfg.secretUnits;
      serviceConfig.UMask = "0027";
    };
  };
}

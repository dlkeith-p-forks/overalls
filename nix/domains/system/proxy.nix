{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.marshallProxy;
  localTypes = import ./types.nix { inherit lib; };
  names = builtins.attrNames cfg.backends;
  content = cfg.artifactContent;
  contentEnabled = content.host != null;
  contentHost = if contentEnabled then lib.toLower content.host else "";
  # @cc [owner:ghuntley,label:security] proxy-artifact-content-isolation
  # The content host shares the public listener by SNI and Host only. Its
  # requests MUST lose Cookie, Authorization and Proxy-Authorization, MUST be
  # limited to GET and HEAD (405 otherwise) and MUST reach only
  # marshall_artifact_nodes; Marshall's host MUST reach only marshall_nodes.
  # Any other Host MUST still receive 421. Without a content host the frontend
  # is unchanged.
  frontendRules = if !contentEnabled then [
    "http-request deny deny_status 421 unless public_host"
    "http-request del-header Forwarded"
    "http-request set-header X-Forwarded-Proto https"
    "http-request set-header X-Forwarded-Host ${cfg.publicHost}"
    "http-request set-header X-Forwarded-For %[src]"
    "default_backend marshall_nodes"
  ] else [
    "acl content_host hdr(host),lower -m str ${contentHost} ${contentHost}:${toString cfg.port}"
    "http-request deny deny_status 421 unless public_host || content_host"
    "http-request deny deny_status 405 if content_host !METH_GET"
    "http-request del-header Cookie if content_host"
    "http-request del-header Authorization if content_host"
    "http-request del-header Proxy-Authorization if content_host"
    "http-request del-header Forwarded"
    "http-request set-header X-Forwarded-Proto https"
    "http-request set-header X-Forwarded-Host ${cfg.publicHost} if public_host"
    "http-request set-header X-Forwarded-Host ${contentHost} if content_host"
    "http-request set-header X-Forwarded-For %[src]"
    "use_backend marshall_artifact_nodes if content_host"
    "use_backend marshall_nodes if public_host"
  ];
  backendServer = name: backend: port:
    "server ${name} ${backend.address}:${toString port} resolve-prefer ipv4 ssl verify required verifyhost ${backend.serverName} sni str(${backend.serverName})";
  runtime = cfg.bindAddressFile != null;
  variable = "MARSHALL_PROXY_BIND_IPV4";
  addressDirectory = "/run/marshall-proxy-address";
  # Refuses an absent or non-canonical runtime address before HAProxy parses a
  # bind line, so a quoted "${VAR}:443" can never degrade to a wildcard.
  guard = pkgs.writeShellScript "marshall-proxy-address-guard" ''
    value="''${${variable}-}"
    octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    if ! [[ "$value" =~ ^$octet(\.$octet){3}$ ]] || [ "$value" = 0.0.0.0 ]; then
      echo '{"event":"proxy.runtime_address_refused","severity":"error"}' >&2
      exit 1
    fi
  '';
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
    bindAddressFile = mkOption {
      type = types.nullOr (types.strMatching "/run/[A-Za-z0-9_./-]+");
      default = null;
      description = "Runtime file holding the explicit listener IPv4 address (for example a decrypted SOPS bundle output), used instead of bindAddress so the address never enters the Nix store. Every HAProxy listener derived from this proxy binds it.";
    };
    bindAddressUnit = mkOption {
      type = types.nullOr (types.strMatching "[a-zA-Z0-9_.@-]+\\.service");
      default = null;
      description = "Unit that publishes bindAddressFile; the proxy address unit follows it.";
    };
    bindSpec = mkOption {
      type = types.functionTo types.str;
      readOnly = true;
      internal = true;
      default = port: if runtime
        then ''"''${${variable}}:${toString port}"''
        else "${cfg.bindAddress}:${toString port}";
      description = "HAProxy bind argument for a port on the proxy address: the literal, or the quoted runtime environment reference.";
    };
    addressUnits = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      internal = true;
      default = lib.optional runtime "marshall-proxy-address.service";
      description = "Units every HAProxy consumer of the proxy address must follow.";
    };
    addressEnvironmentFile = mkOption {
      type = types.nullOr types.str;
      readOnly = true;
      internal = true;
      default = if runtime then "${addressDirectory}/address.env" else null;
      description = "EnvironmentFile carrying the validated runtime address variable for every HAProxy consumer.";
    };
    addressGuard = mkOption {
      type = types.nullOr types.str;
      readOnly = true;
      internal = true;
      default = if runtime then "${guard}" else null;
      description = "ExecStartPre/ExecReload command refusing a missing or non-canonical runtime address; consumers order it first.";
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
    artifactContent = {
      host = mkOption {
        type = types.nullOr ((types.addCheck types.str (value: builtins.match "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+" value != null)) // { description = "lowercase multi-label DNS hostname"; });
        default = null;
        description = "Lowercase public DNS name of the isolated artifact content origin, served on the same HTTPS listener by SNI and Host. Null routes no content traffic.";
      };
      certificateFile = mkOption {
        type = types.nullOr localTypes.privatePath;
        default = null;
        description = "Atomically published PEM key and full certificate chain for the content host, readable by the haproxy group. Required with host; ACME sets it when enabled.";
      };
    };
    backends = mkOption {
      default = {};
      description = "Marshall TLS endpoints, keyed by backend identity.";
      type = types.attrsOf (types.submodule ({ config, ... }: {
        options = {
          address = mkOption {
            type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9.-]*";
            description = "Backend IPv4 address or hostname.";
          };
          port = mkOption { type = types.port; default = 4443; description = "Backend HTTPS port."; };
          artifactPort = mkOption {
            type = types.port;
            default = config.port + 2000;
            description = "Backend artifact content HTTPS port, used only when artifactContent.host is set. Health follows the browser port's readiness check.";
          };
          serverName = mkOption {
            type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9.-]*";
            description = "Required certificate hostname and TLS SNI for traffic and health checks.";
          };
        };
      }));
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      { assertion = names != [] && builtins.length names <= 100;
        message = "Marshall proxy requires 1..100 explicitly configured TLS backends."; }
      { assertion = lib.all (name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}" name != null) names;
        message = "Marshall proxy backend names must be valid identifiers."; }
      { assertion = !config.services.marshall.enable || lib.all (instance: instance.port != cfg.port && instance.fleetPort != cfg.port
          && (config.services.marshall.artifactContent.host == null || instance.artifactPort != cfg.port))
          (builtins.attrValues config.services.marshall.instances);
        message = "Marshall proxy and local backend ports must be distinct."; }
      { assertion = contentEnabled == (content.certificateFile != null)
          && (!contentEnabled || (contentHost != lib.toLower cfg.publicHost && content.certificateFile != cfg.certificateFile));
        message = "Marshall proxy artifactContent requires a host distinct from publicHost and its own certificateFile, set together."; }
      { assertion = !config.services.marshall.enable || config.services.marshall.artifactContent.host == content.host;
        message = "A colocated Marshall and proxy must configure the same artifactContent.host."; }
      { assertion = runtime == (cfg.bindAddressUnit != null) && (!runtime || cfg.bindAddress == "0.0.0.0");
        message = "A runtime proxy address requires bindAddressUnit and replaces bindAddress."; }
      { assertion = !runtime || !cfg.openFirewall || (config.overalls.fleetFirewall.enable or false);
        message = "A runtime proxy address cannot open a destination-scoped listener without the fleet firewall; set openFirewall = false or admit it through fleet firewall runtime listeners."; }
    ];
    networking.firewall = mkIf (cfg.openFirewall && !runtime) (import ./listener-firewall.nix {
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
        bind ${cfg.bindSpec cfg.port} ssl crt ${cfg.certificateFile}${lib.optionalString contentEnabled " crt ${content.certificateFile}"} alpn h2,http/1.1
        acl public_host hdr(host),lower -m str ${lib.toLower cfg.publicHost} ${lib.toLower cfg.publicHost}:${toString cfg.port}
        ${lib.concatStringsSep "\n  " frontendRules}

      backend marshall_nodes
        balance roundrobin
        option httpchk
        http-check send meth GET uri /health/ready ver HTTP/1.1 hdr Host ${cfg.publicHost}
        http-check expect status 200
        default-server inter 1s fall 2 rise 2
        ${lib.concatStringsSep "\n  " (lib.mapAttrsToList (name: backend:
          "${backendServer name backend backend.port} check check-ssl check-sni ${backend.serverName} ca-file ${cfg.backendCAFile}") cfg.backends)}
    '' + lib.optionalString contentEnabled ''

      # @cc [owner:ghuntley,label:security] proxy-artifact-content-backend
      # Content backends MUST verify the same backend CA and hostname, MUST
      # take health only from the matching marshall_nodes server (the content
      # listener has no health route), MUST strip credentials again and MUST
      # delete every Set-Cookie before a content response leaves the proxy.
      backend marshall_artifact_nodes
        balance roundrobin
        http-request del-header Cookie
        http-request del-header Authorization
        http-request del-header Proxy-Authorization
        http-response del-header Set-Cookie
        ${lib.concatStringsSep "\n  " (lib.mapAttrsToList (name: backend:
          "${backendServer name backend backend.artifactPort} ca-file ${cfg.backendCAFile} track marshall_nodes/${name}") cfg.backends)}
    '';

    # @cc [owner:ghuntley,label:security] proxy-reload-and-diagnostics
    # TLS files MUST remain outside the store and be reread on validated reload.
    # Request logs MUST exclude URLs, headers, credentials and terminal payloads.
    systemd.services.haproxy = {
      after = cfg.secretUnits ++ cfg.addressUnits;
      requires = cfg.secretUnits ++ cfg.addressUnits;
      serviceConfig = lib.mkMerge [
        { UMask = "0027"; }
        (mkIf runtime {
          EnvironmentFile = cfg.addressEnvironmentFile;
          ExecStartPre = lib.mkOrder 400 [ cfg.addressGuard ];
          ExecReload = lib.mkOrder 400 [ cfg.addressGuard ];
        })
      ];
    };

    # @cc [owner:ghuntley,label:security;deployment] proxy-runtime-bind-address
    # A runtime proxy address MUST be validated as a canonical explicit IPv4
    # address before any HAProxy listener derived from the proxy starts or
    # reloads, and each such listener MUST bind exactly that address. A missing,
    # wildcard or malformed value MUST fail closed instead of binding everywhere.
    systemd.services.marshall-proxy-address = mkIf runtime {
      description = "Validate the runtime Marshall proxy listener address";
      after = [ cfg.bindAddressUnit ];
      requires = [ cfg.bindAddressUnit ];
      # Each consumer start retries validation; refusals must not exhaust a
      # start limit that would then block the corrected address.
      startLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        RuntimeDirectory = "marshall-proxy-address";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = true;
        ExecStart = lib.escapeShellArgs [ "${pkgs.python3}/bin/python3" "${./proxy-address.py}"
          "--address-file" cfg.bindAddressFile "--variable" variable "--output" "${addressDirectory}/address.env" ];
        NoNewPrivileges = true;
        PrivateNetwork = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ addressDirectory ];
      };
    };
  };
}

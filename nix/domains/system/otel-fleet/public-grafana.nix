{ config, lib, ... }:
let
  fleet = config.services.overallsOtelFleet;
  cfg = fleet.publicGrafana;
  proxy = config.services.marshallProxy;
  marshall = config.services.marshall or { enable = false; };
  # A runtime proxy address is unknown at evaluation, so every listener on the
  # Grafana port conflicts regardless of its address.
  runtime = proxy.bindAddressFile != null;
  addressConflicts = address: runtime || builtins.elem address [ proxy.bindAddress "0.0.0.0" ];
  streamConflicts = stream: builtins.elem stream [
    "${proxy.bindAddress}:${toString cfg.port}" "0.0.0.0:${toString cfg.port}" (toString cfg.port)
  ] || (runtime && lib.hasSuffix ":${toString cfg.port}" stream);
  socketConflict = lib.any (socket: (socket.enable or true) && lib.any streamConflicts socket.listenStreams)
    (builtins.attrValues config.systemd.sockets);
  ssh = config.services.openssh;
  sshConflict = ssh.enable && (if ssh.listenAddresses == []
    then builtins.elem cfg.port ssh.ports
    else lib.any (listener: addressConflicts listener.addr &&
      (if listener.port == null then builtins.elem cfg.port ssh.ports else listener.port == cfg.port)) ssh.listenAddresses);
  serviceConflict = name:
    let service = lib.attrByPath [ "services" name ] {} config;
    in (service.enable or false) && addressConflicts (service.bindAddress or "127.0.0.1")
      && (service.port or 0) == cfg.port;
  origin = "https://${proxy.publicHost}:${toString cfg.port}";
in {
  imports = [ ../proxy.nix ../fleet-firewall.nix ];
  options.services.overallsOtelFleet.publicGrafana = {
    enable = lib.mkEnableOption "authenticated public Grafana HTTPS through the existing proxy";
    port = lib.mkOption {
      type = lib.types.ints.between 1 65535;
      default = 3443;
      description = "Public Grafana HTTPS port on the Marshall proxy's explicit IPv4 address and hostname.";
    };
  };

  # @cc [owner:ghuntley,label:security;deployment] grafana-public-boundary
  # Public Grafana MUST retain application authentication, loopback backend
  # custody and the proxy's runtime TLS certificate. Its destination-scoped
  # firewall grant and frontend MUST NOT include other telemetry listeners or
  # contribute to Marshall's public ingress measurement.
  config = lib.mkMerge [
    { assertions = [{
      assertion = !cfg.enable || (fleet.enable && fleet.role == "central" && proxy.enable);
      message = "Public Grafana requires enabled central fleet telemetry and Marshall HTTPS proxy.";
    }]; }
    (lib.mkIf cfg.enable {
      assertions = [
        { assertion = runtime || proxy.bindAddress != "0.0.0.0";
          message = "Public Grafana requires an explicit IPv4 listener address."; }
        { assertion = !runtime || config.overalls.fleetFirewall.enable;
          message = "Public Grafana on a runtime proxy address requires the fleet firewall's runtime listener."; }
        { assertion = !builtins.elem cfg.port [ proxy.port 3000 8405 9090 3200 ]
            && !socketConflict && !sshConflict && !lib.any serviceConflict [ "porsche" "enrico" ]
            && (!marshall.enable || lib.all
              (instance: instance.port != cfg.port && instance.fleetPort != cfg.port)
              (builtins.attrValues marshall.instances));
          message = "Public Grafana port conflicts with a local proxy, backend or telemetry listener."; }
      ];
      services.grafana.settings = {
        server = { domain = proxy.publicHost; root_url = "${origin}/"; enforce_domain = true; };
        security.cookie_secure = true;
      };
      services.haproxy.config = lib.mkAfter ''
        frontend grafana_public
          bind ${proxy.bindSpec cfg.port} ssl crt ${proxy.certificateFile} alpn h2,http/1.1
          acl grafana_host hdr(host),lower -m str ${lib.toLower proxy.publicHost} ${lib.toLower proxy.publicHost}:${toString cfg.port}
          http-request deny deny_status 421 unless grafana_host
          http-request del-header Forwarded
          http-request set-header X-Forwarded-Proto https
          http-request set-header X-Forwarded-Host ${proxy.publicHost}:${toString cfg.port}
          http-request set-header X-Forwarded-For %[src]
          default_backend grafana_loopback

        backend grafana_loopback
          option httpchk
          http-check send meth GET uri /api/health ver HTTP/1.1 hdr Host ${proxy.publicHost}:${toString cfg.port}
          http-check expect status 200
          server grafana 127.0.0.1:3000 check
      '';
      # The proxy's listeners share one perimeter entry: the same literal, or
      # the same runtime file and unit as the HTTP-01 listener.
      overalls.fleetFirewall.publicServices.marshall-proxy = lib.mkIf config.overalls.fleetFirewall.enable {
        address = lib.mkIf (!runtime) proxy.bindAddress;
        addressFile = lib.mkIf runtime proxy.bindAddressFile;
        addressUnit = lib.mkIf runtime proxy.bindAddressUnit;
        tcpPorts = [ cfg.port ];
        comment = "Marshall proxy public listeners";
      };
      networking.firewall = lib.mkIf (!config.overalls.fleetFirewall.enable && !runtime)
        (import ../listener-firewall.nix {
          inherit lib config; address = proxy.bindAddress; tcpPorts = [ cfg.port ];
        });
    })
  ];
}

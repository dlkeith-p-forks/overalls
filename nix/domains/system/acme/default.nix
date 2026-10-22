{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.marshallProxy.acme;
  dns = cfg.challengeType == "dns-01";
  proxy = config.services.marshallProxy;
  localTypes = import ../types.nix { inherit lib; };
  httpsURL = types.strMatching "https://[a-zA-Z0-9][a-zA-Z0-9.:/-]*";
  python = pkgs.python3.withPackages (packages: [ packages.cryptography ]);
  clientConfig = pkgs.writeText "marshall-acme-client.json" (builtins.toJSON ({
    inherit (cfg) challengeType caFile;
    lego = "${pkgs.lego}/bin/lego";
    timeoutSeconds = 300;
  } // lib.optionalAttrs dns { inherit (cfg) route53; }));
  client = pkgs.writeShellScriptBin "lego" ''
    exec ${pkgs.python3}/bin/python ${./lego.py} ${clientConfig} "$@"
  '';
  contentHost = proxy.artifactContent.host;
  content = contentHost != null;
  marshallDestination = "/var/lib/overalls-certificates/marshall";
  contentDestination = "/var/lib/overalls-certificates/marshall-artifact-content";
  # Each certificate publishes independently. A sibling that has never been
  # published is substituted only inside the candidate configuration check, so
  # the first issued certificate does not wait for the other name.
  publicationFor = { unit, host, destination, peers }: pkgs.writeText "${unit}-publication.json" (builtins.toJSON {
    runtime = "/run/${unit}";
    inherit destination;
    peerCertificates = map (peer: "${peer}/full.pem") peers;
    source = "/var/lib/acme/${host}/full.pem";
    issuer = if config.security.acme.useRoot then "root" else "acme";
    group = config.services.haproxy.group;
    hostname = host;
    # A runtime proxy address reaches the probe only through the validated
    # environment variable, never through this store file.
    listenAddress = if proxy.bindAddressFile == null then proxy.bindAddress else null;
    listenAddressVariable = if proxy.bindAddressFile == null then null else "MARSHALL_PROXY_BIND_IPV4";
    listenPort = proxy.port;
    inherit (cfg) caFile minimumValiditySeconds;
    bundleLibrary = "${../secrets/prepare.py}";
    openssl = "${pkgs.openssl}/bin/openssl";
    haproxy = "${config.services.haproxy.package}/bin/haproxy";
    systemctl = "${pkgs.systemd}/bin/systemctl";
    proxyConfig = "/etc/haproxy.cfg";
  });
  publication = publicationFor {
    unit = "marshall-certificate"; host = proxy.publicHost; destination = marshallDestination;
    peers = lib.optional content contentDestination;
  };
  contentPublication = publicationFor {
    unit = "marshall-artifact-certificate"; host = contentHost; destination = contentDestination;
    peers = [ marshallDestination ];
  };
  certificate = host: {
    inherit (cfg) email server;
    dnsProvider = if dns then "route53" else null;
    dnsResolver = if dns then cfg.route53.dnsResolver else null;
    webroot = null;
    listenHTTP = if dns then null else
      "${cfg.http01.bindAddress}:${toString cfg.http01.port}";
    dnsPropagationCheck = true;
    enableDebugLogs = false;
    credentialFiles = lib.optionalAttrs (dns && cfg.route53.credentialsFile != null) {
      AWS_SHARED_CREDENTIALS_FILE = cfg.route53.credentialsFile;
    };
  };
  publisher = { unit, host, file, description }: {
    inherit description;
    after = [ "acme-${host}.service" "systemd-tmpfiles-setup.service" ] ++ proxy.addressUnits;
    requires = [ "acme-${host}.service" ] ++ proxy.addressUnits;
    serviceConfig = lib.optionalAttrs (proxy.addressEnvironmentFile != null) {
      EnvironmentFile = proxy.addressEnvironmentFile;
      ExecStartPre = [ proxy.addressGuard ];
    } // {
      Type = "oneshot";
      User = "root";
      Group = "root";
      UMask = "0077";
      RuntimeDirectory = unit;
      RuntimeDirectoryMode = "0700";
      StateDirectory = "overalls-certificates";
      StateDirectoryMode = "0755";
      ExecStart = "${python}/bin/python ${./publish.py} ${file}";
      ExecStopPost = "${python}/bin/python ${./publish.py} --cleanup ${file}";
      TimeoutStartSec = 120;
      PrivateDevices = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
    };
  };
in
{
  imports = [ ./http.nix ];
  options.services.marshallProxy.acme = {
    enable = mkEnableOption "ACME issuance and validated proxy certificate publication";
    challengeType = mkOption { type = types.enum [ "http-01" "dns-01" ]; default = "http-01"; description = "Domain validation method; DNS-01 uses Route 53."; };
    email = mkOption { type = types.strMatching "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9][a-zA-Z0-9.-]*"; description = "ACME account contact email."; };
    route53 = {
      hostedZoneId = mkOption { type = types.nullOr (types.strMatching "[A-Z0-9]+"); default = null; description = "Route 53 hosted zone authorized for this hostname's TXT challenge; required for DNS-01."; };
      region = mkOption { type = types.strMatching "[a-z0-9-]+"; default = "us-east-1"; description = "AWS signing region."; };
      credentialsFile = mkOption { type = types.nullOr localTypes.privatePath; default = null; description = "Private AWS shared credentials INI with only the default profile; required for DNS-01."; };
      dnsResolver = mkOption { type = types.nullOr (types.strMatching "[a-zA-Z0-9][a-zA-Z0-9.-]*:[0-9]{1,5}"); default = null; description = "Optional IPv4 recursive DNS resolver or hostname including its port."; };
      endpoint = mkOption { type = types.nullOr httpsURL; default = null; description = "Optional verified HTTPS Route 53 endpoint for isolated fixtures or compatible services."; };
    };
    secretUnits = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service");
      default = [];
      description = "Prerequisites publishing issuer trust or selected DNS credentials before issuance.";
    };
    server = mkOption { type = httpsURL; default = "https://acme-v02.api.letsencrypt.org/directory"; description = "Verified HTTPS ACME directory."; };
    caFile = mkOption {
      type = localTypes.absolutePath;
      default = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      description = "Trust bundle for the ACME/Route 53 endpoints and issued public certificate.";
    };
    minimumValiditySeconds = mkOption { type = types.ints.positive; default = 3600; description = "Minimum remaining lifetime before a certificate can be published."; };
  };

  config = mkIf cfg.enable {
    assertions = [
      { assertion = proxy.enable; message = "Marshall ACME publication requires the proxy to be enabled."; }
      { assertion = config.services.haproxy.user != "root" && config.services.haproxy.group != "root"; message = "Marshall ACME requires an unprivileged proxy user and group."; }
      { assertion = proxy.certificateFile == "/var/lib/overalls-certificates/marshall/full.pem"; message = "ACME must own the proxy's published certificate path."; }
      { assertion = !content || proxy.artifactContent.certificateFile == "${contentDestination}/full.pem"; message = "ACME must own the proxy's published artifact content certificate path."; }
      { assertion = !dns || (cfg.route53.hostedZoneId != null && cfg.route53.credentialsFile != null); message = "DNS-01 requires route53.hostedZoneId and route53.credentialsFile."; }
    ];
    services.marshallProxy.certificateFile = "/var/lib/overalls-certificates/marshall/full.pem";
    services.marshallProxy.artifactContent.certificateFile = mkIf content "${contentDestination}/full.pem";
    system.build = lib.optionalAttrs dns { marshallRoute53Policy = pkgs.writeText "marshall-route53-policy.json" (builtins.toJSON {
      Version = "2012-10-17";
      Statement = [
        { Effect = "Allow"; Action = [ "route53:GetChange" ]; Resource = "arn:aws:route53:::change/*"; }
        { Effect = "Allow"; Action = [ "route53:ListResourceRecordSets" ]; Resource = "arn:aws:route53:::hostedzone/${cfg.route53.hostedZoneId}"; }
        {
          Effect = "Allow";
          Action = [ "route53:ChangeResourceRecordSets" ];
          Resource = "arn:aws:route53:::hostedzone/${cfg.route53.hostedZoneId}";
          Condition."ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = [ "_acme-challenge.${lib.toLower proxy.publicHost}" ]
              ++ lib.optional content "_acme-challenge.${contentHost}";
            "route53:ChangeResourceRecordSetsRecordTypes" = [ "TXT" ];
          };
        }
      ];
    }); };
    security.acme.certs = {
      ${proxy.publicHost} = certificate proxy.publicHost // {
        postRun = ''
          ${pkgs.systemd}/bin/systemctl --no-block start marshall-certificate.service
        '';
      };
    } // lib.optionalAttrs content {
      # @cc [owner:ghuntley,label:security;deployment] acme-artifact-content-certificate
      # The artifact content host MUST receive its own single-name certificate
      # (no wildcard) through the same challenge method, account and
      # validated publication as publicHost. Its HTTP-01 order MUST follow the
      # publicHost order so the two never contend for the responder port.
      ${contentHost} = certificate contentHost // {
        postRun = ''
          ${pkgs.systemd}/bin/systemctl --no-block start marshall-artifact-certificate.service
        '';
      };
    };
    systemd.services = {
      "acme-order-renew-${proxy.publicHost}" = {
        path = lib.mkBefore [ client ];
        after = cfg.secretUnits;
        requires = cfg.secretUnits;
        serviceConfig.TimeoutStartSec = 360;
      };

      # @cc [owner:ghuntley,label:recovery] proxy-publication-oneshot
      # A publication attempt MUST finish before proxy startup and remain a
      # completed oneshot, so later updates do not propagate a proxy stop.
      marshall-certificate = publisher {
        unit = "marshall-certificate"; host = proxy.publicHost; file = publication;
        description = "Validate and publish Marshall's issued proxy certificate";
      };
      haproxy = {
        after = [ "marshall-certificate.service" ] ++ lib.optional content "marshall-artifact-certificate.service";
        wants = [ "marshall-certificate.service" ] ++ lib.optional content "marshall-artifact-certificate.service";
        serviceConfig.ExecStartPre = lib.mkBefore ([
          "${python}/bin/python ${./publish.py} --cached ${publication}"
        ] ++ lib.optional content "${python}/bin/python ${./publish.py} --cached ${contentPublication}");
        serviceConfig.ExecReload = lib.mkBefore ([
          "${python}/bin/python ${./publish.py} --cached ${publication}"
        ] ++ lib.optional content "${python}/bin/python ${./publish.py} --cached ${contentPublication}");
      };
    } // lib.optionalAttrs content {
      "acme-order-renew-${contentHost}" = {
        path = lib.mkBefore [ client ];
        after = cfg.secretUnits ++ [ "acme-order-renew-${proxy.publicHost}.service" ];
        requires = cfg.secretUnits;
        serviceConfig.TimeoutStartSec = 360;
      };
      marshall-artifact-certificate = publisher {
        unit = "marshall-artifact-certificate"; host = contentHost; file = contentPublication;
        description = "Validate and publish Marshall's issued artifact content certificate";
      };
    };
    systemd.timers = {
      marshall-certificate = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnBootSec = "30s"; OnUnitActiveSec = "15min"; Unit = "marshall-certificate.service"; };
      };
    } // lib.optionalAttrs content {
      marshall-artifact-certificate = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnBootSec = "45s"; OnUnitActiveSec = "15min"; Unit = "marshall-artifact-certificate.service"; };
      };
    };
  };
}

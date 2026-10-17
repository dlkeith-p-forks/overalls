{ pkgs, nixpkgs, module }:
let
  inherit (pkgs) lib;
  evaluate = settings: (nixpkgs.lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [ module {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
    } settings ];
  }).config;
  settings = port: nft: {
    # This focused fixture has no guest intake or provisioner.
    services.overallsOtelGuest.enable = lib.mkForce false;
    services.overallsOtelFleet = {
      enable = true; role = "central";
      publicGrafana = { enable = true; inherit port; };
    };
    overalls.fleetNetwork = {
      enable = true; address = "10.90.0.1"; endpointAddress = "192.0.2.10";
      privateKeyFile = "/run/fleet/key";
      peers.worker = { address = "10.90.0.2"; endpointAddress = "192.0.2.11"; publicKey = lib.concatStrings (lib.replicate 43 "A") + "="; };
    };
    overalls.fleetFirewall.enable = true;
    networking.nftables.enable = nft;
    networking.enableIPv6 = false;
    services.marshallProxy = {
      enable = true; bindAddress = "192.0.2.10"; publicHost = "overalls.test";
      certificateFile = "/run/tls/full.pem";
      backends.local = { address = "127.0.0.1"; serverName = "overalls.test"; };
    };
  };
  valid = cfg: lib.all (item: item.assertion) cfg.assertions;
  # ADR-0181 public HTTP-01 ingress shares the proxy's single perimeter entry.
  http01 = grafana: publicIngress: evaluate (lib.recursiveUpdate (settings 3443 true) {
    services.overallsOtelFleet.publicGrafana.enable = grafana;
    services.marshallProxy.certificateFile = "/var/lib/overalls-certificates/marshall/full.pem";
    services.marshallProxy.acme = { enable = true; email = "noreply@overalls.test"; http01.publicIngress = publicIngress; };
    security.acme.acceptTerms = true;
  });
  proxyPorts = cfg: (cfg.overalls.fleetFirewall.publicServices.marshall-proxy or { tcpPorts = []; }).tcpPorts;
  disabled = evaluate {};
  checkPort = port: nft:
    let cfg = evaluate (settings port nft);
        rules = if nft then cfg.networking.firewall.extraInputRules else cfg.networking.firewall.extraCommands;
    in assert lib.assertMsg (valid cfg) (builtins.toJSON (map (a: a.message) (builtins.filter (a: !a.assertion) cfg.assertions))); true
      && cfg.services.grafana.settings.server.root_url == "https://overalls.test:${toString port}/"
      && cfg.services.grafana.settings.server.http_addr == "127.0.0.1"
      && cfg.services.grafana.settings.security.cookie_secure
      && !cfg.services.grafana.settings."auth.anonymous".enabled
      && !cfg.services.grafana.settings.users.allow_sign_up
      && cfg.overalls.fleetFirewall.publicServices.marshall-proxy.tcpPorts == [ port ]
      && lib.hasInfix "192.0.2.10" rules
      && lib.hasInfix (toString port) rules
      && cfg.networking.firewall.allowedTCPPorts == []
      && lib.hasInfix "frontend grafana_public" cfg.services.haproxy.config;
  rejected = settings:
    let result = builtins.tryEval (valid (evaluate settings));
    in !result.success || !result.value;
  cases = {
    ninetyDayRetention =
      let cfg = evaluate (settings 3443 true); in
      cfg.services.prometheus.retentionTime == "90d"
        && cfg.services.prometheus.extraFlags == []
        && cfg.services.tempo.settings.compactor.compaction.block_retention == "2160h";
    generatedRetention = lib.all (days:
      let cfg = evaluate (lib.recursiveUpdate (settings 3443 true) {
        services.overallsOtelFleet = { metricsRetentionDays = days; tracesRetentionDays = days; };
      }); in cfg.services.prometheus.retentionTime == "${toString days}d"
        && cfg.services.tempo.settings.compactor.compaction.block_retention == "${toString (days * 24)}h"
    ) [ 7 30 90 180 365 ];
    defaultOff = !disabled.services.overallsOtelFleet.publicGrafana.enable
      && disabled.overalls.fleetFirewall.publicServices == {};
    bothBackends = checkPort 3443 true && checkPort 3443 false;
    standaloneBackends = lib.all (nft:
      let cfg = evaluate (lib.recursiveUpdate (settings 3443 nft) {
        overalls.fleetFirewall.enable = false;
      });
      in valid cfg && cfg.overalls.fleetFirewall.publicServices == {}
        && lib.hasInfix "3443" (if nft then cfg.networking.firewall.extraInputRules else cfg.networking.firewall.extraCommands)
    ) [ true false ];
    enabledTelemetryOptOut =
      let cfg = evaluate (lib.recursiveUpdate (settings 3443 true) {
        services.overallsOtelFleet.publicGrafana.enable = false;
      });
      in valid cfg && cfg.overalls.fleetFirewall.publicServices == {}
        && !lib.hasInfix "frontend grafana_public" cfg.services.haproxy.config;
    generatedPorts = lib.all (port: checkPort port true && checkPort port false)
      (builtins.genList (index: 12000 + index * 997) 12);
    disabledTelemetryRejected = rejected { services.overallsOtelFleet.publicGrafana.enable = true; };
    workerRejected = rejected (lib.recursiveUpdate (settings 3443 true) {
      services.overallsOtelFleet.role = "worker";
    });
    wildcardRejected = rejected (lib.recursiveUpdate (settings 3443 true) {
      services.marshallProxy.bindAddress = "0.0.0.0";
    });
    conflictsRejected = lib.all (port: rejected (settings port true)) [ 443 3000 3200 8405 9090 ];
    socketConflictRejected = rejected (lib.recursiveUpdate (settings 12345 true) {
      systemd.sockets.other = { listenStreams = [ "192.0.2.10:12345" ]; };
    });
    sshConflictRejected = rejected (lib.recursiveUpdate (settings 2222 true) {
      services.openssh = { enable = true; ports = [ 2222 ]; };
    });
    zeroPortRejected = rejected (settings 0 true);
    http01PublicMerged = let cfg = http01 true true; in valid cfg
      && lib.sort lib.lessThan (proxyPorts cfg) == [ 80 3443 ]
      && lib.hasInfix ''ip daddr 192.0.2.10 tcp dport 80 accept'' cfg.networking.firewall.extraInputRules;
    http01PublicDefaultOff = let cfg = http01 true false; in valid cfg
      && proxyPorts cfg == [ 3443 ]
      && !lib.hasInfix "tcp dport 80 " cfg.networking.firewall.extraInputRules;
    http01PublicAlone = let cfg = http01 false true; in valid cfg && proxyPorts cfg == [ 80 ];
    proxyRequired = rejected (lib.recursiveUpdate (settings 3443 true) {
      services.marshallProxy.enable = false;
    });
  };
in assert lib.assertMsg (lib.all (value: value) (builtins.attrValues cases)) (builtins.toJSON cases);
pkgs.writeText "overalls-public-grafana-configuration.json" (builtins.toJSON cases)

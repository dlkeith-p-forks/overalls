{ packages }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.audiPrivate;
  otelEnabled = lib.attrByPath [ "services" "overallsOtelGuest" "enable" ] false config;
  fleetOtelEnabled = lib.attrByPath [ "services" "overallsOtelFleet" "enable" ] false config;
  paths = import ./types.nix { inherit lib; };
  namespace = "lilly-${builtins.substring 0 12 (builtins.hashString "sha256" config.services.lilly.hostId)}";
  runtime = pkgs.writeText "audi-private-runtime.json" (builtins.toJSON {
    version = 1;
    role = "private";
    # @cc [owner:ghuntley,label:deployment] audi-private-replacement-runtime-binding
    # Only a bounded test fixture may carry the placeholder host marker; deployed
    # configurations keep the enrolled host identity.
    host_id = if cfg.configurationFile != null then "@replacement-host-id@" else config.services.lilly.hostId;
    connector_path = "/run/lilly-ingress/private.sock";
    ziggy_socket = "/run/ziggy/proxy.sock";
    galileo_socket = "/run/galileo/proxy.sock";
    otel_socket = if otelEnabled then "/run/overalls-otel-guest/receiver.sock" else null;
    certificate_file = "/run/audi-private/credentials/chain.pem";
    key_file = "/run/audi-private/credentials/key.pem";
    roots_file = "/run/audi-private/credentials/roots.pem";
    status_socket = "/run/audi-private/status.sock";
  });
in {
  options.services.audiPrivate = {
    enable = lib.mkEnableOption "Audi private service DNS and TLS in the Lilly namespace";
    package = lib.mkOption { type = lib.types.package; default = packages.audi; };
    configurationFile = lib.mkOption { type = lib.types.nullOr lib.types.path; default = null; description = "Runtime configuration override for the replacement host; default keeps the deployed configuration."; };
    secretsFile = lib.mkOption { type = paths.absolutePath; description = "SOPS document containing AUDI_PRIVATE_CERTIFICATE_CHAIN and AUDI_PRIVATE_CERTIFICATE_KEY (fleet wildcard leaf)."; };
    rootsFile = lib.mkOption { type = paths.absolutePath; description = "Public private-service CA trust bundle, also supplied to guest images."; };
    secretUnits = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
    certificateFile = lib.mkOption { type = paths.privatePath; default = "/run/overalls-secrets/audi-private/chain.pem"; readOnly = true; description = "Fleet wildcard leaf and intermediate PEM chain from the bundle."; };
    keyFile = lib.mkOption { type = paths.privatePath; default = "/run/overalls-secrets/audi-private/key.pem"; readOnly = true; description = "Fleet wildcard leaf key from the bundle; rotation is operator custody."; };
  };

  # @cc [owner:ghuntley,label:security] audi-private-fleet-wildcard-custody
  # Private TLS uses the offline fleet wildcard certificate delivered through
  # the SecretSpec bundle. No per-host issuance, renewal agent or signing
  # authority exists on any host; rotating the certificate is an operator
  # re-encrypt and redeploy.
  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = config.services.lilly.enable && config.services.ziggy.enable && config.services.galileo.enable;
        message = "Audi private services must run beside enabled Lilly, Ziggy and Galileo services."; }
    ];
    services.lilly.privateServices.enable = true;
    services.overallsSecrets.enable = true;
    services.overallsSecrets.bundles.audi-private = {
      encryptedFile = cfg.secretsFile;
      group = "audi";
      outputs = {
        "chain.pem" = { format = "raw"; secrets = [ "AUDI_PRIVATE_CERTIFICATE_CHAIN" ]; };
        "key.pem" = { format = "raw"; secrets = [ "AUDI_PRIVATE_CERTIFICATE_KEY" ]; };
      };
    };
    services.audiPrivate.secretUnits = [ "overalls-secrets-audi-private.service" ];
    users.groups.audi = {};
    users.users.audi = { isSystemUser = true; group = "audi"; extraGroups = [ "ziggy-proxy" "galileo-proxy" ] ++ lib.optional otelEnabled "overalls-otel-guest"; };
    systemd.services.audi-private = {
      description = "Audi internal service DNS and TLS";
      preStart = ''
        ${pkgs.lib.optionalString (cfg.configurationFile != null) ''
          ${pkgs.coreutils}/bin/install -m 0644 ${runtime} ${cfg.configurationFile}.seed
          ${pkgs.python3}/bin/python3 -c "import pathlib,sys; p=pathlib.Path(sys.argv[2]); seed=pathlib.Path(sys.argv[1]).read_text().replace(\"@replacement-host-id@\", pathlib.Path(sys.argv[3]).read_text().strip()); p.write_text(seed)" ${cfg.configurationFile}.seed ${cfg.configurationFile} /run/lilly-release-host-id
        ''}
        ${pkgs.coreutils}/bin/mkdir -p -m 0700 /run/audi-private/credentials
        for credential in chain.pem key.pem roots.pem; do
          ${pkgs.coreutils}/bin/install -m 0400 "$CREDENTIALS_DIRECTORY/$credential" "/run/audi-private/credentials/$credential"
        done
      '';
      # @cc [owner:ghuntley,label:recovery;deployment] audi-private-follows-lilly-start
      # Requires= propagates a Lilly stop to private Audi but never a later
      # start. Private Audi MUST be wanted by lilly.service so every Lilly start
      # (restart, stop/start, enrollment rollback) restores the status socket
      # that Lilly.Private.Readiness requires before admitting new execution.
      wantedBy = [ "multi-user.target" "lilly.service" ];
      after = [ "lilly.service" "ziggy.service" "galileo.service" ] ++ cfg.secretUnits;
      requires = [ "lilly.service" "ziggy.service" "galileo.service" ] ++ cfg.secretUnits;
      environment = {
        AUDI_CONFIG_FILE = if cfg.configurationFile != null then cfg.configurationFile else runtime;
        RELEASE_DISTRIBUTION = "none";
        RELEASE_TMP = "/run/audi-private";
        ERL_CRASH_DUMP = "/dev/null";
        ERL_FLAGS = "+S 4:4";
      } // lib.optionalAttrs fleetOtelEnabled {
        AUDI_SLO_SNAPSHOT = "/run/audi-private/slo.json";
      };
      script = ''
        export RELEASE_COOKIE
        RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
        exec ${cfg.package}/bin/audi start
      '';
      serviceConfig = {
        Type = "exec";
        User = "audi";
        Group = "audi";
        UMask = "0077";
        NetworkNamespacePath = "/run/netns/${namespace}";
        LoadCredential = [ "chain.pem:${cfg.certificateFile}" "key.pem:${cfg.keyFile}" "roots.pem:${cfg.rootsFile}" ];
        RuntimeDirectory = "audi-private";
        RuntimeDirectoryMode = "0700";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 30;
        KillMode = "control-group";
        LimitNOFILE = 65536;
        MemoryMax = "4096M";
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };
  };
}

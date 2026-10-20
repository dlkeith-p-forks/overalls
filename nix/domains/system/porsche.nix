{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.porsche;
  otelEnabled = lib.attrByPath [ "services" "overallsOtelFleet" "enable" ] false config;
  paths = import ./types.nix { inherit lib; };
  hostCertificate = import ./ssh-host-certificate.nix { inherit pkgs packages; inherit (cfg) caFile credentialFile; role = "porsche"; origin = cfg.controlPlane; };
  dumps = import ./crash-dumps { inherit lib pkgs; };
  bind = import ./runtime-bind.nix { inherit lib pkgs; };
  runtimeBind = cfg.bindAddressFile != null;
  # A runtime bind renders the store template into the private runtime directory.
  configFile = if runtimeBind then "/run/porsche/config.json" else runtime;
  runtime = pkgs.writeText "porsche-runtime.json" (builtins.toJSON {
    version = 1;
    control_plane = cfg.controlPlane;
    public_origin = cfg.publicOrigin;
    credential_file = "/run/porsche/gateway.token";
    cacertfile = "/run/credentials/porsche.service/ca.pem";
    host_key_dir = "/var/lib/porsche/keys";
    bind = cfg.bindAddress;
    port = cfg.port;
    status_socket = "/run/porsche/status.sock";
  });
in {
  imports = [ ./crash-dumps/retention.nix ];
  options.services.porsche = {
    enable = mkEnableOption "Porsche SSH machine management";
    package = mkOption {
      type = types.package;
      default = if cfg.crashDumps.enable then packages.encrypted.porsche else packages.porsche;
      description = "Independent source-built Porsche release.";
    };
    controlPlane = mkOption { type = types.str; description = "Verified HTTPS Marshall origin."; };
    publicOrigin = mkOption { type = types.str; description = "Public HTTPS origin for browser key approval."; };
    credentialFile = mkOption {
      type = paths.privatePath;
      description = "Private runtime file containing a separately provisioned Marshall gateway token.";
    };
    caFile = mkOption {
      type = paths.absolutePath;
      default = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      description = "CA certificates authenticating the Marshall HTTPS endpoint.";
    };
  } // bind.options { description = "the Porsche SSH listener"; } cfg // {
    port = mkOption { type = types.port; default = 22; };
    # @cc [owner:ghuntley,label:security] porsche-administrative-access-mode
    # Physical-host defaults MUST retain administrative SSH on 2222. Explicit
    # console-only mode MUST forbid OpenSSH rather than create a root SSH path.
    administrativeAccess = mkOption {
      type = types.enum [ "openssh" "console" ];
      default = "openssh";
      description = "Administrative access path. Console-only deployments must disable administrative OpenSSH.";
    };
    openFirewall = mkOption { type = types.bool; default = false; };
    secretUnits = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service");
      default = [];
      description = "Credential preparation services required before startup.";
    };
    cpuCores = mkOption { type = types.ints.positive; default = 2; };
    memoryMiB = mkOption { type = types.ints.positive; default = 1024; };
    crashDumps = dumps.options;
  };

  config = mkIf cfg.enable {
    assertions = [
      { assertion = cfg.port != 22 || cfg.administrativeAccess == "console" || (config.services.openssh.enable
          && builtins.elem 2222 config.services.openssh.ports
          && !builtins.elem 22 config.services.openssh.ports);
        message = "Porsche on port 22 requires administrative OpenSSH on 2222 with port 22 removed."; }
      { assertion = cfg.administrativeAccess != "console" || !config.services.openssh.enable;
        message = "Console-only administration requires administrative OpenSSH to be disabled."; }
      { assertion = !config.services.openssh.enable || !builtins.elem cfg.port config.services.openssh.ports;
        message = "Porsche and administrative OpenSSH must use distinct ports."; }
      { assertion = !cfg.crashDumps.enable || cfg.crashDumps.publicKeyFile != null;
        message = "Porsche encrypted dumps require an operator public key file."; }
    ] ++ bind.assertions "Porsche" cfg;
    users.groups.porsche = {};
    users.users.porsche = { isSystemUser = true; group = "porsche"; };
    networking.firewall = mkIf (cfg.openFirewall && cfg.bindAddress != null) (import ./listener-firewall.nix {
      inherit lib config; address = cfg.bindAddress; tcpPorts = [ cfg.port ];
    });
    services.overallsCrashDumpRetention.directories = lib.optional cfg.crashDumps.enable "/var/lib/porsche-crash-dumps";
    systemd.coredump.settings.Coredump = mkIf cfg.crashDumps.enable { Storage = "none"; ProcessSizeMax = 0; };

    # @cc [owner:ghuntley,label:security] porsche-service-custody
    # Porsche MUST run as a dedicated unprivileged user, receive gateway secrets
    # through systemd credentials and keep a persistent host key separate from
    # administrative SSH. Restart MUST NOT replace an existing host key.
    systemd.services.porsche-ssh-certificate = hostCertificate.service;
    systemd.timers.porsche-ssh-certificate = hostCertificate.timer;
    # @cc [owner:ghuntley,label:security;deployment] porsche-runtime-bind-address
    # A runtime bind address MUST arrive only as a systemd credential from its
    # publishing unit, which Porsche follows. Startup MUST refuse a missing,
    # non-canonical or wildcard address without logging it, and render the
    # configuration privately under /run/porsche, never into the Nix store.
    systemd.services.porsche = lib.mkMerge [ hostCertificate.startup (bind.unitConfig cfg) {
      description = "Porsche SSH management gateway";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ] ++ cfg.secretUnits;
      requires = cfg.secretUnits;
      environment = {
        PORSCHE_CONFIG_FILE = configFile;
        RELEASE_TMP = "/run/porsche";
        RELEASE_DISTRIBUTION = "none";
        ERL_CRASH_DUMP = "/dev/null";
        ERL_FLAGS = "+S ${toString cfg.cpuCores}:${toString cfg.cpuCores}";
      } // lib.optionalAttrs otelEnabled { PORSCHE_SLO_SNAPSHOT = "/run/porsche/slo.json"; };
      path = [ pkgs.openssh ];
      preStart = ''
        set -eu
      '' + lib.optionalString runtimeBind ''
        ${bind.validate}
        ${bind.read "bind_address" cfg "bind-address"}
        ${bind.render { template = runtime; output = configFile; }}
      '' + ''
        ${pkgs.coreutils}/bin/install -m 0400 "$CREDENTIALS_DIRECTORY/gateway.token" /run/porsche/gateway.token
        ${pkgs.coreutils}/bin/mkdir -p -m 0700 /var/lib/porsche/keys
        if ! test -e /var/lib/porsche/keys/ssh_host_ed25519_key && ! test -L /var/lib/porsche/keys/ssh_host_ed25519_key; then
          ${pkgs.coreutils}/bin/rm -f /run/porsche/new-host-key /run/porsche/new-host-key.pub
          ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f /run/porsche/new-host-key
          ${pkgs.coreutils}/bin/mv /run/porsche/new-host-key /var/lib/porsche/keys/ssh_host_ed25519_key
          ${pkgs.coreutils}/bin/mv /run/porsche/new-host-key.pub /var/lib/porsche/keys/ssh_host_ed25519_key.pub
        fi
        ${hostCertificate.command}
      '';
      script = ''
        export RELEASE_COOKIE
        RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
        exec ${dumps.launch cfg.crashDumps cfg.package "/var/lib/porsche-crash-dumps" "${cfg.package}/bin/porsche start"}
      '';
      serviceConfig = {
        Type = "exec";
        User = "porsche";
        Group = "porsche";
        UMask = "0077";
        LoadCredential = [ "gateway.token:${cfg.credentialFile}" "ca.pem:${cfg.caFile}" ]
          ++ bind.credential cfg "bind-address";
        StateDirectory = [ "porsche" ] ++ lib.optional cfg.crashDumps.enable "porsche-crash-dumps";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "porsche";
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = cfg.package;
        ExecStopPost = lib.optional cfg.crashDumps.enable (dumps.finish "/var/lib/porsche-crash-dumps");
        TimeoutStopSec = 30;
        KillMode = "control-group";
        CPUQuota = "${toString (cfg.cpuCores * 100)}%";
        MemoryMax = "${toString cfg.memoryMiB}M";
        LimitNOFILE = 65536;
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
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    } ];
  };
}

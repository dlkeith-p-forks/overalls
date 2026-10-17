{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.marshall.smtpRelay;
  upstream = cfg.upstream;
  paths = import ../types.nix { inherit lib; };
  hostname = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9.-]*";

  acme = config.services.marshallProxy.acme or { enable = false; };
  httpAcme = acme.enable && acme.challengeType == "http-01";

  # Quote regex metacharacters, not shell syntax, for the relay's Go regexp.
  senderPattern = "^" + lib.escape [ "\\" "." "+" "*" "?" "(" ")" "[" "]" "{" "}" "^" "$" "|" ] cfg.from + "$";
  args = [
    "-listen=127.0.0.1:${toString cfg.port}"
    "-metrics_listen=127.0.0.1:${toString cfg.metricsPort}"
    "-hostname=${config.services.marshall.publicHost}"
    "-allowed_nets=127.0.0.1/32" "-allowed_sender=${senderPattern}"
    "-remote_host=${upstream.host}:${toString upstream.port}"
    "-remote_tls=${upstream.tls}" "-remote_auth=${upstream.auth}"
    "-max_connections=${toString cfg.maxConnections}"
    "-max_message_size=${toString cfg.maxMessageSize}" "-max_recipients=1"
    "-read_timeout=10s" "-write_timeout=10s" "-data_timeout=10s"
    "-log_level=error"
  ];
in {
  options.services.marshall.smtpRelay = {
    enable = mkEnableOption "host-local synchronous SMTP forwarding";
    from = mkOption { type = types.str; default = ""; description = "Verified envelope and message sender address."; };
    port = mkOption { type = types.port; default = 2525; };
    metricsPort = mkOption { type = types.port; default = 9469; };
    maxConnections = mkOption { type = types.ints.between 1 1000; default = 100; };
    maxMessageSize = mkOption { type = types.ints.between 1024 10485760; default = 1048576; };
    secretUnits = mkOption { type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service"); default = []; };
    upstream = {
      provider = mkOption { type = types.enum [ "generic" "ses" "resend" ]; default = "generic"; };
      region = mkOption { type = types.nullOr hostname; default = null; };
      host = mkOption {
        type = types.nullOr hostname;
        default = if upstream.provider == "resend" then "smtp.resend.com"
          else if upstream.provider == "ses" && upstream.region != null
          then "email-smtp.${upstream.region}.amazonaws.com" else null;
      };
      tls = mkOption { type = types.enum [ "starttls" "implicit" ]; default = if upstream.provider == "resend" then "implicit" else "starttls"; };
      port = mkOption { type = types.port; default = if upstream.tls == "implicit" then 465 else 587; };
      auth = mkOption { type = types.enum [ "plain" "login" ]; default = "plain"; };
      usernameFile = mkOption { type = types.nullOr paths.privatePath; default = null; };
      passwordFile = mkOption { type = types.nullOr paths.privatePath; default = null; };
      caFile = mkOption { type = paths.absolutePath; default = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"; };
    };
  };
  config = mkIf cfg.enable {
    assertions = [
      { assertion = config.services.marshall.enable; message = "SMTP relay requires Marshall."; }
      { assertion = builtins.match "[a-zA-Z0-9!#$%&'*+/=?^_`{|}~-]+(\\.[a-zA-Z0-9!#$%&'*+/=?^_`{|}~-]+)*@[a-zA-Z0-9][a-zA-Z0-9.-]*\\.[a-zA-Z]{2,63}" cfg.from != null;
        message = "SMTP relay requires a valid sender address."; }
      { assertion = upstream.host != null && upstream.passwordFile != null
          && (upstream.usernameFile != null || upstream.provider == "resend")
          && (upstream.provider != "ses" || upstream.region != null);
        message = "SMTP relay requires an endpoint, credentials and SES region when selected."; }
      { assertion = cfg.port != cfg.metricsPort && lib.all (port: !(builtins.elem port
          ((lib.concatMap (i: [ i.port i.fleetPort ]) (builtins.attrValues config.services.marshall.instances))
          ++ lib.optionals (config.services.marshallProxy.enable or false) [ config.services.marshallProxy.port ]
          ++ lib.optionals httpAcme [ 80 acme.http01.port ]))) [ cfg.port cfg.metricsPort ];
        message = "SMTP relay ports must not collide with managed listeners."; }
    ];
    systemd.services.overalls-smtprelay = {
      description = "Marshall synchronous SMTP relay";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ] ++ cfg.secretUnits;
      requires = cfg.secretUnits;
      environment.OTEL_SDK_DISABLED = "true";
      script = ''
        exec ${packages.smtprelay}/bin/smtprelay ${lib.escapeShellArgs args} \
          -remote_ca="$CREDENTIALS_DIRECTORY/upstream-ca" \
          -remote_pass_file="$CREDENTIALS_DIRECTORY/password" \
          ${if upstream.usernameFile != null then ''-remote_user_file="$CREDENTIALS_DIRECTORY/username"'' else "-remote_user=resend"}
      '';
      serviceConfig = {
        Type = "exec";
        DynamicUser = true;
        UMask = "0077";
        LoadCredential = [ "password:${upstream.passwordFile}" "upstream-ca:${upstream.caFile}" ]
          ++ lib.optional (upstream.usernameFile != null) "username:${upstream.usernameFile}";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 12;
        MemoryMax = "256M";
        TasksMax = 128;
        LimitCORE = 0;
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
    };
  };
}

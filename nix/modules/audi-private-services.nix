{ pkgs, cfg, namespacePath, runtime, renewal }:
let
  python = pkgs.python3.withPackages (p: [ p.cryptography ]);
in
# @cc [owner:ghuntley,label:security;deployment] shared-private-audi-custody
# Physical and nested private Audi MUST share the restricted certificate renewal
# and frontend services. The frontend MUST enter the exact owned namespace,
# without a host-network fallback, and receive only its leaf key, chain and public
# roots through systemd credentials. Renewal MUST use authenticated verified TLS.
{
  systemd.services.audi-private-certificate = {
    description = "Audi individual host private certificate renewal";
    preStart = ''
      for credential in audi.token control-ca.pem; do
        ${pkgs.coreutils}/bin/install -m 0400 "$CREDENTIALS_DIRECTORY/$credential" "/run/audi-private-renewal/$credential"
      done
    '';
    after = [ "network-online.target" ] ++ cfg.secretUnits;
    wants = [ "network-online.target" ];
    requires = cfg.secretUnits;
    serviceConfig = {
      Type = "oneshot";
      User = "audi";
      Group = "audi";
      UMask = "0077";
      RuntimeDirectory = "audi-private-renewal";
      RuntimeDirectoryMode = "0700";
      StateDirectory = "audi-private-certificates";
      StateDirectoryMode = "0700";
      LoadCredential = [ "audi.token:${cfg.credentialFile}" "control-ca.pem:${cfg.controlCAFile}" ];
      # The HTTP authority may still be starting after its systemd unit is
      # active. Retry bounded acquisition; each attempt honors any valid certificate already published.
      TimeoutStartSec = 300;
      ExecStart = pkgs.writeShellScript "audi-private-acquire-certificate" ''
        for attempt in $(${pkgs.coreutils}/bin/seq 1 30); do
          if ${python}/bin/python3 ${../../audi/priv/private_pki}/renew.py ${renewal}; then
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 2
        done
        exit 1
      '';
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };
  systemd.timers.audi-private-certificate = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "5m"; OnUnitActiveSec = "1d"; RandomizedDelaySec = "1h"; };
  };
  # The frontend uses credential snapshots. Restart after a successful renewal
  # so a replaced key and chain are loaded together.
  systemd.services.audi-private-certificate.serviceConfig.ExecStartPost = "+${pkgs.writeShellScript "audi-reload-private-certificate" ''
    if test -f /var/lib/audi-private-certificates/reload-required; then
      ${pkgs.systemd}/bin/systemctl --no-block try-restart audi-private.service
      ${pkgs.coreutils}/bin/rm /var/lib/audi-private-certificates/reload-required
    fi
  ''}";
  systemd.services.audi-private = {
    description = "Audi internal service DNS and TLS";
    preStart = ''
      ${pkgs.coreutils}/bin/mkdir -p -m 0700 /run/audi-private/credentials
      for credential in chain.pem key.pem roots.pem; do
        ${pkgs.coreutils}/bin/install -m 0400 "$CREDENTIALS_DIRECTORY/$credential" "/run/audi-private/credentials/$credential"
      done
    '';
    # Required-by-Lilly stop propagation MUST be paired with start propagation;
    # see audi-private-follows-lilly-start.
    wantedBy = [ "multi-user.target" "lilly.service" ];
    after = [ "lilly.service" "ziggy.service" ] ++ cfg.certificateUnits;
    requires = [ "lilly.service" "ziggy.service" ] ++ cfg.certificateUnits;
    environment = {
      AUDI_CONFIG_FILE = runtime;
      RELEASE_DISTRIBUTION = "none";
      RELEASE_TMP = "/run/audi-private";
      ERL_CRASH_DUMP = "/dev/null";
      ERL_FLAGS = "+S 4:4";
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
      NetworkNamespacePath = namespacePath;
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
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
  };
}

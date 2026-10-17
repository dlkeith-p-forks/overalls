{ packages }:
{ pkgs, ... }:
{
  users.groups.audi-dns = {};
  users.users.audi-dns = { isSystemUser = true; group = "audi-dns"; };
  systemd.services.inception-dns = {
    wantedBy = [ "multi-user.target" ];
    requires = [ "inception-enrollment.service" "inception-namespace.service" "inception-dns-identity.service" ];
    after = [ "inception-enrollment.service" "inception-namespace.service" "inception-dns-identity.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
    script = "exec ${pkgs.python3}/bin/python3 ${./.}/roles.py ${../.}";
  };

  # @cc [owner:ghuntley,label:security] inception-dns-service-boundary
  # The inner DNS role MUST use only its own DNS credential and verified local
  # Marshall TLS. It MUST bind loopback IPv4 without gateway keys or connector
  # privileges. Missing parent public settings MUST leave this role disabled;
  # its startup MUST NOT gate namespace exchange or core execution readiness.
  systemd.services.audi-dns = {
    wantedBy = [ "multi-user.target" ];
    requires = [ "inception-dns.service" ];
    after = [ "inception-dns.service" "marshall-inception.service" ];
    unitConfig.ConditionPathExists = "/run/inception/dns.json";
    environment = {
      AUDI_CONFIG_FILE = "/run/credentials/audi-dns.service/runtime.json";
      RELEASE_TMP = "/run/audi-dns"; RELEASE_DISTRIBUTION = "none";
      ERL_CRASH_DUMP = "/dev/null"; ERL_FLAGS = "+S 2:2";
    };
    script = ''
      ${pkgs.coreutils}/bin/install -m 0400 "$CREDENTIALS_DIRECTORY/dns.token" /run/audi-dns/dns.token
      export RELEASE_COOKIE
      RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
      exec ${packages.audi}/bin/audi start
    '';
    serviceConfig = {
      Type = "exec"; User = "audi-dns"; Group = "audi-dns"; UMask = "0077";
      LoadCredential = [
        "dns.token:/var/lib/inception/dns.token"
        "runtime.json:/run/inception/dns.json"
        "ca.pem:/run/inception-public/ca.crt"
      ];
      RuntimeDirectory = "audi-dns"; RuntimeDirectoryMode = "0700";
      Restart = "on-failure"; RestartSec = 5; TimeoutStopSec = 30;
      KillMode = "control-group"; CPUQuota = "100%"; MemoryMax = "512M";
      LimitNOFILE = 4096;
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      NoNewPrivileges = true; PrivateDevices = true; PrivateTmp = true;
      ProtectSystem = "strict"; ProtectHome = true;
      ProtectKernelTunables = true; ProtectKernelModules = true; ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
      RestrictSUIDSGID = true; LockPersonality = true;
    };
  };
}

{ packages }:
{ lib, pkgs, ... }:
let
  bootstrap = ../emulation/host/private_bootstrap.py;
  origin = pkgs.runCommand "overalls-inner-loopback-origin" {} ''
    mkdir -p "$out/origin"
    cp ${../fixtures/origin/__init__.py} "$out/origin/__init__.py"
    cp ${../fixtures/origin/server.py} "$out/origin/server.py"
    cp ${../fixtures/origin/loopback.py} "$out/origin/loopback.py"
  '';
  role = name: user: configVariable: {
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    requires = [ "lilly-private-config.service" ];
    after = [ "lilly-private-config.service" "network-online.target" ];
    environment = {
      ${configVariable} = "/run/${name}/config.json";
      RELEASE_DISTRIBUTION = "none";
      RELEASE_TMP = "/run/${name}";
      ERL_CRASH_DUMP = "/dev/null";
      ERL_FLAGS = "+S 1:1";
    };
    serviceConfig = {
      User = user;
      Group = user;
      UMask = if user == "audi" then "0077" else "0007";
      Restart = "on-failure";
      RestartSec = 3;
      ExecStart = pkgs.writeShellScript "overalls-inner-${name}" ''
        export RELEASE_COOKIE="$(${pkgs.openssl}/bin/openssl rand -hex 32)"
        exec ${packages.${user}}/bin/${user} start
      '';
    };
  };
in {
  # @cc [owner:ghuntley,label:security;verification] inner-private-service-custody
  # Real private roles MUST use separate UIDs, local Unix sockets and runtime
  # credentials bound to this enrolled inner host. Images contain no keys.
  users.groups.audi.gid = 991;
  users.groups.ziggy.gid = 992;
  users.groups.galileo.gid = 993;
  users.users.audi = {
    isSystemUser = true; uid = 991; group = "audi";
    extraGroups = [ "ziggy" "galileo" ];
  };
  users.users.ziggy = { isSystemUser = true; uid = 992; group = "ziggy"; };
  users.users.galileo = { isSystemUser = true; uid = 993; group = "galileo"; };
  networking.interfaces.lo.ipv4.addresses = [ { address = "169.254.254.1"; prefixLength = 32; } ];
  systemd.tmpfiles.rules = [ "d /run/lilly-ingress 2750 root audi -" ];
  systemd.services.lilly.requires = [ "lilly-private-pki.service" ];
  systemd.services.lilly.after = [ "lilly-private-pki.service" ];
  systemd.services.lilly-private-pki = {
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.openssl ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
      ExecStart = "${pkgs.python313}/bin/python3 ${bootstrap} prepare";
    };
  };
  systemd.services.lilly-private-config = {
    wantedBy = [ "multi-user.target" ];
    requires = [ "lilly-private-pki.service" ];
    after = [ "lilly-private-pki.service" "run-overalls\\x2dsecrets.mount" ];
    path = [ pkgs.openssl ];
    # Enrollment arrives after the first host boot. Successful retry must
    # start roles whose initial dependency jobs were refused.
    unitConfig.OnSuccess = "ziggy.service galileo.service audi-private.service lilly-inner-origin.service";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
      Restart = "on-failure";
      RestartSec = 5;
      ExecStart = "${pkgs.python313}/bin/python3 ${bootstrap} configure";
    };
  };
  systemd.services.lilly-inner-origin = {
    wantedBy = [ "multi-user.target" ];
    requires = [ "lilly-private-config.service" ];
    after = [ "lilly-private-config.service" ];
    path = [ pkgs.git pkgs.coreutils ];
    environment.PYTHONPATH = toString origin;
    serviceConfig = {
      UMask = "0077";
      ExecStart = "${pkgs.python313}/bin/python3 -m origin.loopback --state /var/lib/lilly-host/origin --key /run/overalls-secrets/inner-openai.key";
      Restart = "on-failure";
      RestartSec = 3;
    };
  };
  systemd.services.ziggy = lib.recursiveUpdate (role "ziggy" "ziggy" "ZIGGY_CONFIG_FILE") {
    wants = [ "network-online.target" "lilly-inner-origin.service" ];
    after = [ "lilly-private-config.service" "lilly-inner-origin.service" "network-online.target" ];
  };
  systemd.services.galileo = role "galileo" "galileo" "GALILEO_CONFIG_FILE";
  systemd.services.audi-private = lib.recursiveUpdate (role "audi-private" "audi" "AUDI_CONFIG_FILE") {
    requires = [ "lilly-private-config.service" "lilly.service" "ziggy.service" "galileo.service" ];
    after = [ "lilly-private-config.service" "lilly.service" "ziggy.service" "galileo.service" ];
    serviceConfig = {
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
    };
  };
}

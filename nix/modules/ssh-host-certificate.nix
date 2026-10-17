# @cc [owner:ghuntley,label:security;recovery] gateway-certificate-runtime-only
# Both gateways MUST use the same certificate installer. It may read only its
# own runtime credential and host key. Failed renewal MUST not delete a valid
# certificate, and no private key may enter the descriptor or Nix store.
{ pkgs, packages, role, origin, caFile, credentialFile }:
let
  descriptor = pkgs.writeText "${role}-ssh-certificate.json" (builtins.toJSON {
    inherit role origin;
    key_dir = "/var/lib/${role}/keys";
  });
  command = "${packages.lyra}/bin/overalls-host-certificate ${descriptor}";
in {
  inherit command;
  # @cc [owner:ghuntley,label:recovery] gateway-initial-certificate-retry
  # Missing initial authority MUST keep SSH closed and retry at a bounded rate
  # without a terminal start limit. A remote issuer may recover after any boot
  # ordering window; recovery MUST NOT require operator reset-failed.
  startup = {
    startLimitIntervalSec = 0;
    serviceConfig = { Restart = "on-failure"; RestartSec = 5; };
  };
  service = {
    description = "Renew ${role} SSH host certificate";
    requires = [ "${role}.service" ];
    after = [ "${role}.service" ];
    path = [ pkgs.openssh ];
    serviceConfig = {
      Type = "oneshot";
      User = role;
      Group = role;
      UMask = "0077";
      ExecStart = command;
      LoadCredential = [ "gateway.token:${credentialFile}" "ca.pem:${caFile}" ];
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/${role}/keys" ];
      ProtectHome = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
    };
  };
  timer = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "5m"; OnUnitActiveSec = "1d"; RandomizedDelaySec = "5m"; };
  };
}

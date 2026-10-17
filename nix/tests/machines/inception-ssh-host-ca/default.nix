{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "overalls-inception-ssh-host-ca";
  defaults = { lib, ... }: {
    imports = [ ../../../packages/guest/inception/ssh-host-ca.nix ];
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    environment.systemPackages = [ pkgs.openssh pkgs.jq ];
    users.groups.ca-probe = {};
    users.users.ca-probe = { isSystemUser = true; group = "ca-probe"; };
    systemd.services.inception-identity = {
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = "install -d -m 0700 /var/lib/inception /run/inception";
    };
    systemd.services.inception-namespace = {
      requires = [ "inception-identity.service" ];
      after = [ "inception-identity.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        printf '%s\n' control.example.test > /run/inception/public-host
        printf '%s\n' '{"origins":{"apps":"apps.example.test"}}' > /run/inception/ingress.json
      '';
    };
    # The real namespace/CA service and systemd credential boundary are under
    # test. This probe is not a substitute for the nested Marshall/VM journey.
    systemd.services.marshall-inception = {
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.openssh ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "ca-probe";
        RuntimeDirectory = "ssh-ca-probe";
        EnvironmentFile = "/run/inception/ssh-trust.env";
      };
      script = ''
        printf '%s\n' "$MARSHALL_SSH_HOST_TRUST" > /run/ssh-ca-probe/policy.json
        ssh-keygen -y -f "$MARSHALL_SSH_HOST_CA_KEY_FILE" > /run/ssh-ca-probe/public-key
      '';
    };
  };
  nodes.first = {};
  nodes.second = {};
  testScript = builtins.readFile ./test.py;
}

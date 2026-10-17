# A preinstalled, public-fixture certificate lets service-custody tests exercise
# startup and outage behavior without inventing a working Marshall authority.
{ pkgs, role }:
assert builtins.elem role [ "porsche" "audi" ];
{ ... }:
{
  systemd.services.${role} = {
    requires = [ "${role}-certificate-fixture.service" ];
    after = [ "${role}-certificate-fixture.service" ];
  };
  systemd.services."${role}-certificate-fixture" = {
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
    path = [ pkgs.openssh pkgs.coreutils pkgs.jq ];
    script = ''
      install -d -m 0700 /run/${role}-certificate-fixture /var/lib/${role}/keys
      install -m 0600 ${../fixtures/ssh-host-ca/key} /run/${role}-certificate-fixture/ca
      cd /var/lib/${role}/keys
      ssh-keygen -q -t ed25519 -N "" -C "" -f ssh_host_ed25519_key
      ssh-keygen -q -s /run/${role}-certificate-fixture/ca -h -I custody-fixture \
        -n control.example.test -V -5m:+3650d ssh_host_ed25519_key.pub
      jq -n --rawfile certificate ssh_host_ed25519_key-cert.pub \
        --rawfile ca ${../fixtures/ssh-host-ca/key.pub} \
        '{version: 1, certificate: $certificate, ca: ($ca | rtrimstr("\n")), principal: "control.example.test"}' \
        > certificate.json
      chown -R ${role}:${role} /var/lib/${role}/keys
    '';
  };
}

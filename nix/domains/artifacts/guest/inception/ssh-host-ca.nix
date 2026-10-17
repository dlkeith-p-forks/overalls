# @cc [owner:ghuntley,label:security;recovery] inception-independent-ssh-ca
# Each nested deployment MUST generate and retain its own SSH CA outside the
# image, never receive the parent CA private key. Only inner Marshall may read
# the signer credential. Runtime policy MUST use the accepted parent namespace.
{ pkgs, lib, ... }:
{
  systemd.services.inception-ssh-trust = {
    requires = [ "inception-identity.service" "inception-namespace.service" ];
    after = [ "inception-identity.service" "inception-namespace.service" ];
    path = [ pkgs.openssh pkgs.coreutils pkgs.jq ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
    script = ''
      set -eu
      state=/var/lib/inception/ssh-ca
      if [ ! -e "$state" ] && [ ! -L "$state" ]; then
        stage=$(mktemp -d /var/lib/inception/.ssh-ca.XXXXXXXX)
        trap 'rm -rf "$stage"' EXIT
        ssh-keygen -q -t ed25519 -N "" -C "" -f "$stage/key"
        date -u -d '+20 years' +%s > "$stage/retirement"
        chmod 0600 "$stage"/*
        sync -f "$stage/key"
        mv "$stage" "$state"
        sync -f /var/lib/inception
      fi
      test -d "$state" && test ! -L "$state"
      test "$(stat -c '%u:%a' "$state")" = '0:700'
      for file in key key.pub retirement; do
        test -f "$state/$file" && test ! -L "$state/$file"
        test "$(stat -c '%u:%a' "$state/$file")" = '0:600'
      done
      public_key=$(ssh-keygen -y -f "$state/key")
      test "$public_key" = "$(cut -d ' ' -f 1,2 "$state/key.pub")"
      jq -ner --arg ca "$public_key" --rawfile host /run/inception/public-host \
        --slurpfile ingress /run/inception/ingress.json \
        --rawfile retirement "$state/retirement" '
          {version: 1, ca: $ca, management_host: ($host | rtrimstr("\n")),
           zone: $ingress[0].origins.apps, retirement: ($retirement | rtrimstr("\n") | tonumber)}
          | "MARSHALL_SSH_HOST_TRUST=" + (tojson | tojson)
        ' > /run/inception/ssh-trust.env.new
      mv /run/inception/ssh-trust.env.new /run/inception/ssh-trust.env
    '';
  };
  systemd.services.marshall-inception = {
    requires = [ "inception-ssh-trust.service" ];
    after = [ "inception-ssh-trust.service" ];
    environment.MARSHALL_SSH_HOST_CA_KEY_FILE = "/run/credentials/marshall-inception.service/ssh-host-ca";
    serviceConfig.LoadCredential = lib.mkAfter [ "ssh-host-ca:/var/lib/inception/ssh-ca/key" ];
  };
}

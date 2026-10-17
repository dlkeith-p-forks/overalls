{ pkgs }:
let
  # @cc [owner:ghuntley,label:security;deployment] staging-acme-roots-test-only
  # Audi's staging issuer MUST validate issued leaf chains against only the
  # pinned, official Let's Encrypt staging roots. These deliberately untrusted
  # roots MUST NOT be added to the host or ordinary application trust stores.
  roots = [
    (pkgs.fetchurl {
      url = "https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem";
      hash = "sha256-Ol4RceX1wtQVItQ48iVgLkI2po+ynDI5mpWSGkroDnM=";
    })
    (pkgs.fetchurl {
      url = "https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x2.pem";
      hash = "sha256-SXw2wbUMDa/zCHDVkIybl68pIj1VEMXmwklX0MxQL7g=";
    })
    (pkgs.fetchurl {
      url = "https://letsencrypt.org/certs/staging/gen-y/root-ye.pem";
      hash = "sha256-v0Goxff//BgeRtXfGiuGfw77bhad9vCkW9QGSx0CMIQ=";
    })
    (pkgs.fetchurl {
      url = "https://letsencrypt.org/certs/staging/gen-y/root-yr.pem";
      hash = "sha256-czke1Vo+sJ8ShPi1SOVA9eJlFJyD6gt53YrpfAFmWdc=";
    })
  ];
in
pkgs.runCommand "letsencrypt-staging-roots.pem" { } ''
  for root in ${builtins.concatStringsSep " " roots}; do
    cat "$root" >> "$out"
    printf '\n' >> "$out"
  done
''

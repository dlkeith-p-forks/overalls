{ pkgs, toolchain }:
pkgs.runCommand "inception-runtime-check" { nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.cryptography ])) pkgs.openssl pkgs.git toolchain.elixir ]; } ''
  export PYTHONDONTWRITEBYTECODE=1
  export ERL_FLAGS="+S 2:2"
  # Release eval scripts are outside Mix's compilation scope. Parse every script
  # with the pinned runtime before accepting this configuration check.
  elixir -e '
    [directory] = System.argv()
    for path <- Path.wildcard(Path.join(directory, "*.exs")) do
      Code.string_to_quoted!(File.read!(path), file: path)
    end
  ' ${../../packages/guest/inception}
  python3 -W error ${./marshall-public-host.py} ${../../modules/marshall-public-host.py}
  python3 -W error ${./marshall-default-image.py} ${../../modules/marshall-default-image.py}
  python3 -W error ${./inception-runtime.py} ${../../packages/guest/inception/runtime.py}
  python3 -W error ${./inception-publication.py} ${../../packages/guest/inception}
  python3 -W error ${./inception-observations.py} ${../../packages/guest/inception}
  python3 -W error ${./inception-control-proofs.py} ${../../packages/guest/inception} ${../../../protocol/test/fixtures/inception_public.json}
  python3 -W error ${./inception-control-tls.py} ${../../packages/guest/inception} ${../../modules/acme/publish.py} ${pkgs.openssl}/bin/openssl ${pkgs.haproxy}/bin/haproxy ${../../../protocol/test/fixtures/inception_public.json}
  python3 -W error ${./inception-control-worker.py} ${../../packages/guest/inception} ${../../../protocol/test/fixtures/inception_public.json}
  python3 -W error ${./inception-public-settings.py} ${../../packages/guest/inception} ${../../../protocol/test/fixtures/inception_public.json}
  python3 -W error ${./inception-ingress.py} ${../../packages/guest/inception} ${../../packages/guest/flush.py}
  python3 -W error ${./inception-credentials.py} ${../../packages/guest/inception}
  python3 -W error ${./inception-private-pki.py} ${../../packages/guest/inception} ${../../../audi/priv/private_pki}
  python3 -W error ${./inception-ziggy.py} ${../../packages/guest/inception}
  python3 -W error ${./inception-private-runtime.py} ${../../packages/guest/inception}
  python3 -W error ${./inception-prepare.py} ${../../packages/guest/inception} ${pkgs.openssl}/bin/openssl ${pkgs.git}/bin/git
  touch $out
''

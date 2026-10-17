{ pkgs }:
let python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
in pkgs.runCommand "overalls-enrollment-preparation" {
  nativeBuildInputs = [ python pkgs.sops pkgs.age pkgs.ssh-to-age pkgs.openssh ];
} ''
  cp ${../../../domains/artifacts/secrets/cli.py} "$TMPDIR/secrets_cli.py"
  export PYTHONPATH="$TMPDIR:${../../../domains/artifacts/host}"
  python3 ${./enrollment-preparation.py}
  touch $out
''

{ pkgs }:
let python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
in pkgs.runCommand "overalls-enrollment-preparation" {
  nativeBuildInputs = [ python pkgs.sops pkgs.age pkgs.ssh-to-age pkgs.openssh ];
} ''
  cp ${../../packages/secrets/cli.py} "$TMPDIR/secrets_cli.py"
  export PYTHONPATH="$TMPDIR:${../../packages/host}"
  python3 ${./enrollment-preparation.py}
  touch $out
''

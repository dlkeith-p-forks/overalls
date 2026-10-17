{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ps.hypothesis ]);
in
pkgs.runCommand "overalls-secret-reconciliation" {
  nativeBuildInputs = [ python pkgs.sops pkgs.ssh-to-age pkgs.age pkgs.openssh ];
} ''
  export PYTHONDONTWRITEBYTECODE=1
  python ${./secrets_test.py} ${../../../domains/artifacts/secrets/cli.py}
  python ${./secret_recipient_histories.py} ${../../../domains/artifacts/secrets/cli.py}
  mkdir -p "$out"
  echo passed > "$out/result"
''

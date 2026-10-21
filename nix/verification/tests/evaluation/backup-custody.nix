{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
in
pkgs.runCommand "overalls-backup-custody" {
  nativeBuildInputs = [
    python
    pkgs.sops
    pkgs.ssh-to-age
    pkgs.age
    pkgs.openssh
    pkgs.restic
    pkgs.ruff
    pkgs.ty
  ];
} ''
  export RUFF_CACHE_DIR=$TMPDIR/ruff
  export XDG_CACHE_HOME=$TMPDIR/cache
  export PYTHONDONTWRITEBYTECODE=1
  chmod 0700 "$TMPDIR"
  # Some builders own their private sandbox root, initially mode 1777.
  # Preserve ancestor checks by removing group/world writes on that root;
  # never chmod a root-owned host root or run this normalization as root.
  if [ "$(id -u)" != 0 ] && [ "$(stat -c %u /)" = "$(id -u)" ]; then
    chmod go-w /
  fi
  cp -r ${../../../domains/system/backups} backups
  cp ${../../../domains/artifacts/secrets/cli.py} secrets_cli.py
  cp ${./backup-custody.py} backup_custody_test.py
  cp ${../../../../pyproject.toml} pyproject.toml
  chmod u+w pyproject.toml
  # The cli copy is exercised as a subprocess only; the repository-wide gate's
  # documented argv-driven import suppression stays on the module copy.
  printf '\n[tool.ty.rules]\nunused-ignore-comment = "ignore"\n' >> pyproject.toml
  ruff format --check backups secrets_cli.py backup_custody_test.py
  ruff check backups secrets_cli.py backup_custody_test.py
  ty check --python-version 3.13 --extra-search-path backups backups backup_custody_test.py
  python3 -W error backup_custody_test.py backups secrets_cli.py ${pkgs.restic}/bin/restic -v
  touch $out
''

{ pkgs }:
pkgs.runCommand "overalls-backup-operator-histories" {
  nativeBuildInputs = [ (pkgs.python313.withPackages (ps: [ ps.hypothesis ])) pkgs.restic pkgs.ruff pkgs.ty ];
} ''
  export RUFF_CACHE_DIR=$TMPDIR/ruff
  export XDG_CACHE_HOME=$TMPDIR/cache
  export PYTHONDONTWRITEBYTECODE=1
  chmod 0700 "$TMPDIR"
  cp -r ${../../../domains/system/backups} backups
  cp ${./backup-operators.py} backup_operators_test.py
  cp ${../../../../pyproject.toml} pyproject.toml
  chmod u+w pyproject.toml
  # These sibling modules resolve inside this isolated check, whereas the
  # repository-wide gate needs the documented argv-driven import suppression.
  printf '\n[tool.ty.rules]\nunused-ignore-comment = "ignore"\n' >> pyproject.toml
  ruff format --check backups backup_operators_test.py
  ruff check backups backup_operators_test.py
  ty check --python-version 3.13 --extra-search-path backups backups backup_operators_test.py
  python3 -W error backup_operators_test.py backups ${pkgs.restic}/bin/restic -v
  touch $out
''

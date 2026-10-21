{ pkgs }:
let
  testPython = pkgs.python313.withPackages (ps: [ ps.hypothesis ]);
in
pkgs.runCommand "overalls-backup-types" {
  nativeBuildInputs = [ pkgs.ruff pkgs.ty testPython pkgs.stdenv.cc ];
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
  chmod -R u+w backups
  cp ${../machines/backup-cleanup/native_cleanup.py} backups/native_cleanup_test.py
  cp ${../machines/backup-cleanup/packaged_cleanup.py} backups/packaged_cleanup_test.py
  cp ${../machines/backup-cleanup/zfs_command.py} backups/native_zfs_command.py
  cc -std=c11 -Wall -Wextra -Werror -pthread ${./backup-thread-reader.c} -o backup-thread-reader
  export THREAD_READER=$PWD/backup-thread-reader
  export READER_HELPER=${./backup-reader.py}
  cp ${./backup-reader.py} backup_reader_test.py
  cp ${./backup-state.py} backup_state_test.py
  cp ${./backup-workflow.py} backup_workflow_test.py
  cp ${./guest-flush.py} guest_flush_test.py
  cp ${./backup-status.py} backup_status_test.py
  cp ${../../../domains/system/fleet-exporter/backup_status.py} backup_status.py
  cp ${../../../../pyproject.toml} pyproject.toml
  chmod u+w pyproject.toml
  # The argv/sys.path driven imports in the copied tests carry ty: ignore
  # comments that are only required at the repository root; in this flat
  # sandbox the sibling copies resolve, so unused suppressions are expected.
  printf '\n[tool.ty.rules]\nunused-ignore-comment = "ignore"\n' >> pyproject.toml
  cp ${../../../domains/artifacts/guest/flush.py} flush.py
  ruff format --check backups backup_reader_test.py backup_state_test.py backup_workflow_test.py guest_flush_test.py backup_status_test.py flush.py
  ruff check backups backup_reader_test.py backup_state_test.py backup_workflow_test.py guest_flush_test.py backup_status_test.py flush.py
  ty check --python ${testPython}/bin/python3 --python-version 3.13 backups backup_reader_test.py backup_state_test.py backup_workflow_test.py guest_flush_test.py backup_status_test.py flush.py
  ty check --python ${testPython}/bin/python3 --python-version 3.13 backup_status.py backup_status_test.py
  python3 -W error ${./backup-state.py} backups
  python3 -W error backup_workflow_test.py backups
  python3 -W error backup_status_test.py .
  touch $out
''

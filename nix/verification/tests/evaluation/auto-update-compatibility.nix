{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.hypothesis ]);
in
# @cc [owner:ghuntley,label:verification] updater-compatibility-executable-check
# This check MUST execute the existing fixed assertions and generated histories
# against the supplied production runtime, with standalone typing of the copied
# machine-directory helpers. It MUST NOT claim native deployment acceptance.
pkgs.runCommand "overalls-auto-update-compatibility" {
  nativeBuildInputs = [ python pkgs.ruff pkgs.ty ];
} ''
  export PYTHONDONTWRITEBYTECODE=1
  export RUFF_CACHE_DIR="$TMPDIR/ruff"
  export XDG_CACHE_HOME="$TMPDIR/cache"
  mkdir checks
  cd checks
  cp ${../../../domains/system/auto-update/runtime.py} updater_runtime.py
  cp ${../machines/auto-update/unit.py} unit.py
  cp ${../machines/auto-update/compatibility_histories.py} compatibility_histories.py
  # Keep the repository lint config below this directory so standalone typing
  # cannot inherit its source include filter. Explicitly check all three files.
  mkdir config
  cp ${../../../../pyproject.toml} config/pyproject.toml
  ruff format --check --config config/pyproject.toml .
  ruff check --config config/pyproject.toml .
  ty check --python ${python}/bin/python3 --python-version 3.13 \
    updater_runtime.py unit.py compatibility_histories.py
  python unit.py ./updater_runtime.py
  python compatibility_histories.py
  mkdir -p "$out"
  echo passed > "$out/result"
''

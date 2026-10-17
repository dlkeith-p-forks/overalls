{ pkgs, vscodeWeb }:
let
  python = pkgs.python313.withPackages (packages: [ packages.hypothesis packages.cryptography ]);
in
# @cc [owner:ghuntley,label:verification] extension-maintenance-check-scope
# This check MUST run updater/helper failure and property tests and the actual
# packaged signature/engine validator. It MUST NOT claim native guest LSP proof.
pkgs.runCommand "overalls-vscode-extension-maintenance" {
  nativeBuildInputs = [ python pkgs.ruff pkgs.ty ];
} ''
  export RUFF_CACHE_DIR="$TMPDIR/ruff"
  export XDG_CACHE_HOME="$TMPDIR/cache"
  export PYTHONDONTWRITEBYTECODE=1
  export HYPOTHESIS_STORAGE_DIRECTORY="$TMPDIR/hypothesis"
  export TEST_NODE=${pkgs.nodejs_24}/bin/node
  export TEST_VALIDATOR=${vscodeWeb}/lib/overalls-maintenance/check-extension.mts
  export TEST_SHELL=${pkgs.runtimeShell}
  maintained=nix/packages/vscode-web
  mkdir -p "$maintained"
  cp ${./extensions.py} "$maintained/extensions.py"
  cp ${./update-extensions.py} "$maintained/update-extensions.py"
  cp ${./test_extensions.py} "$maintained/test_extensions.py"
  cp ${./extensions.lock.json} "$maintained/extensions.lock.json"
  cp -r ${./project-language-adapters} "$maintained/project-language-adapters"
  cp ${../../../pyproject.toml} pyproject.toml
  ruff format --check "$maintained"
  ruff check "$maintained"
  ty check --python ${python}/bin/python3 "$maintained"
  python3 -W error "$maintained/test_extensions.py" -v
  touch "$out"
''

{ pkgs }:
let
  # Third-party imports MUST resolve against pinned packages so the type check
  # rejects real interface drift instead of missing modules.
  tyPython = pkgs.python313.withPackages (p: [
    p.aiohttp
    p.boto3
    p.cryptography
    p.dnslib
    p.hypothesis
    p.playwright
    p.pyyaml
    p.websockets
  ]);
  harnessPython = pkgs.python313.withPackages (p: [ p.cryptography ]);
  antithesisWheels = import ../../../../antithesis/nix/python-wheels.nix { inherit pkgs; };
in
# @cc [owner:ghuntley,label:verification] python-static-repository-root
# Formatting, lint and type checks MUST run from the repository root with its
# reviewed pyproject.toml and all maintained Python trees in scope.
pkgs.runCommand "overalls-python-static" {
  nativeBuildInputs = [ pkgs.ruff pkgs.ty ];
} ''
  export RUFF_CACHE_DIR="$TMPDIR/ruff"
  export XDG_CACHE_HOME="$TMPDIR/cache"
  cd ${../../../..}
  ruff format --check .
  ruff check .
  ${pkgs.bash}/bin/bash antithesis/verification/static-check.sh \
    ${pkgs.ty}/bin/ty ${tyPython}/bin/python3 ${harnessPython}/bin/python3 ${antithesisWheels}
  touch $out
''

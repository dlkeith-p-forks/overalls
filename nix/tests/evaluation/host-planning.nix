{ pkgs }:
pkgs.runCommand "overalls-host-planning" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  export PYTHONPATH=${../../packages/host}
  python3 ${./host-planning.py} ${../../modules/auto-update/runtime.py} ${../../modules/auto-update/resources.py}
  python3 ${../machines/auto-update/resources_test.py} ${../../modules/auto-update/resources.py}
  touch $out
''

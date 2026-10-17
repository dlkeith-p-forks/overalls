{ pkgs }:
pkgs.runCommand "overalls-host-planning" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  export PYTHONPATH=${../../../domains/artifacts/host}
  python3 ${./host-planning.py} ${../../../domains/system/auto-update/runtime.py} ${../../../domains/system/auto-update/resources.py}
  python3 ${../machines/auto-update/resources_test.py} ${../../../domains/system/auto-update/resources.py}
  touch $out
''

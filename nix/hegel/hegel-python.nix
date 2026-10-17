# @cc [owner:ghuntley,label:verification] hegel-binding-matches-engine
# The binding MUST load the pinned libhegel and refuse a version mismatch;
# the engine version is substituted at build time from libhegel.expectedVersion.
{ pkgs, libhegel }:
pkgs.python3.pkgs.buildPythonPackage {
  pname = "overalls-hegel";
  version = libhegel.expectedVersion;
  pyproject = true;
  src = ./python;

  build-system = [ pkgs.python3.pkgs.setuptools ];

  postPatch = ''
    substituteInPlace hegel/_lib.py \
      --replace-fail '@LIBHEGEL_C@' '${libhegel}/lib/libhegel_c.so' \
      --replace-fail '@HEGEL_EXPECTED_VERSION@' '${libhegel.expectedVersion}'
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export PYTHONPATH=$PWD:$PYTHONPATH
    python tests/smoke.py passing
    if python tests/smoke.py value_failing > failing.log 2>&1; then
      echo "expected value_failing to exit nonzero" >&2
      exit 1
    fi
    grep -q "FAILED: too_big" failing.log
    grep -q "HEGEL_REPLAY_BLOB=" failing.log
    blob=$(grep -o 'HEGEL_REPLAY_BLOB="[^"]*"' failing.log | head -1 | cut -d'"' -f2)
    if HEGEL_REPLAY_BLOB="$blob" python tests/smoke.py value_failing > replay.log 2>&1; then
      echo "expected replay to exit nonzero" >&2
      exit 1
    fi
    grep -q "replay reproduced the failure" replay.log
    python tests/smoke.py state
    if python tests/smoke.py state_failing > state.log 2>&1; then
      echo "expected state_failing to exit nonzero" >&2
      exit 1
    fi
    grep -q "FAILED: CounterMachine" state.log
    runHook postCheck
  '';
}

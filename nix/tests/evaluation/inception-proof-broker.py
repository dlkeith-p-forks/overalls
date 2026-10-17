"""Exercise the packaged Audi client against the actual guest Python broker."""

import importlib.util
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

source = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("runtime", source / "runtime.py")
if spec is None or spec.loader is None:
    raise RuntimeError("runtime helper unavailable")
runtime = importlib.util.module_from_spec(spec)
sys.modules["runtime"] = runtime
spec.loader.exec_module(runtime)
encode = runtime.encode
observations_spec = importlib.util.spec_from_file_location(
    "observations", source / "observations.py"
)
if observations_spec is None or observations_spec.loader is None:
    raise RuntimeError("observations helper unavailable")
observations = importlib.util.module_from_spec(observations_spec)
sys.modules["observations"] = observations
observations_spec.loader.exec_module(observations)


def check() -> None:
    """@cc [owner:ghuntley,label:verification] inception-cross-runtime-proof-check
    This check MUST use the source-built Audi release and guest proof server over
    a real Unix socket. It MUST check matching evidence, mismatched generation,
    proof and peer UID, and expiry without comparing language clock epochs.
    Fixture UID/path overrides MUST remain outside production configuration.
    """
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        root.chmod(0o750)
        binding = {
            "placement_id": "11111111-1111-4111-8111-111111111111",
            "execution_epoch": 1,
            "boot_challenge": "a" * 64,
        }
        value = {"binding": binding, "generation": 2}
        (root / "input.json").write_bytes(encode(value))
        # Use the writer's real clock; the client explicitly expires this
        # evidence before its final assertion.
        observations.publish_shared(
            root,
            encode(
                dict(
                    value,
                    records=[
                        {
                            "label": "vm-11111111111111111111111111111111",
                            "proofs": ["A" * 43],
                            "expires_at_ms": time.monotonic_ns() // 1000000 + 5000,
                        }
                    ],
                )
            ),
        )
        server = observations.Server(os.getuid(), root)
        try:
            expression = """
              root = System.fetch_env!("PROOF_FIXTURE_ROOT")
              input = Path.join(root, "input.json") |> File.read!() |> JSON.decode!()
              {:ok, source} = Audi.ACME.Observed.new(input, "apps.example")
              source = %{source | path: Path.join(root, "verify.sock"), uid: File.stat!(root).uid}
              host = "vm-11111111111111111111111111111111.apps.example"
              proof = String.duplicate("A", 43)
              true = Audi.ACME.Observed.ready?(host, [proof], source)
              false = Audi.ACME.Observed.ready?(host, [proof], %{source | generation: 3})
              false = Audi.ACME.Observed.ready?(host, [proof], %{source | uid: source.uid + 1})
              other = Base.url_encode64(:binary.copy(<<1>>, 32), padding: false)
              false = Audi.ACME.Observed.ready?(host, [other], source)
              path = Path.join(root, "current.json")
              evidence = path |> File.read!() |> JSON.decode!()
              evidence = Map.update!(evidence, "records", fn records ->
                Enum.map(records, &Map.put(&1, "expires_at_ms", 0))
              end)
              File.write!(path, JSON.encode!(evidence))
              false = Audi.ACME.Observed.ready?(host, [proof], source)
            """
            env = dict(
                os.environ,
                PROOF_FIXTURE_ROOT=str(root),
                RELEASE_DISTRIBUTION="none",
                RELEASE_COOKIE="isolated-proof-fixture",
                RELEASE_TMP=str(root),
                ERL_FLAGS="+S 2:2",
                ERL_CRASH_DUMP="/dev/null",
            )
            subprocess.run([sys.argv[2], "eval", expression], env=env, check=True, timeout=20)
        finally:
            server.close()


check()

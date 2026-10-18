{ pkgs, lyra }:
pkgs.runCommand "overalls-executor-bootstrap-v1" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  mkdir -p "$out"/{linux,windows,freebsd,illumos}-amd64
  cp ${lyra}/bin/linux-amd64 "$out/linux-amd64/executor"
  cp ${lyra.windows}/bin/overalls-agentd-windows.exe "$out/windows-amd64/executor.exe"
  cp ${lyra.native}/bin/x86_64-unknown-freebsd-overalls-native-agentd "$out/freebsd-amd64/executor"
  cp ${lyra.native}/bin/x86_64-unknown-illumos-overalls-native-agentd "$out/illumos-amd64/executor"
  python3 - "$out" <<'PYTHON'
import hashlib
import json
from pathlib import Path
import sys

root: Path = Path(sys.argv[1])
platforms: dict[str, dict[str, str | int]] = {}
for platform in ("linux-amd64", "windows-amd64", "freebsd-amd64", "illumos-amd64"):
    relative: str = platform + ("/executor.exe" if platform == "windows-amd64" else "/executor")
    path: Path = root / relative
    size: int = path.stat().st_size
    assert 0 < size <= 104857600
    with path.open("rb") as stream:
        digest: str = hashlib.file_digest(stream, "sha256").hexdigest()
    platforms[platform] = {"path": relative, "sha256": digest, "bytes": size}
(root / "manifest.json").write_text(json.dumps({"version": 1, "platforms": platforms}, sort_keys=True))
PYTHON
''

{ pkgs }:
# OpenSSH uses the first option value; caller flags cannot repair these defaults.
pkgs.nixos-anywhere.overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.python3 ];
  postPatch = (old.postPatch or "") + ''
    substituteInPlace src/nixos-anywhere.sh \
      --replace-fail '"-o" "UserKnownHostsFile=/dev/null" "-o" "StrictHostKeyChecking=no"' '"-F" "/dev/null" "-o" "StrictHostKeyChecking=yes"'
    python3 - <<'PYCODE'
    from pathlib import Path
    p = Path("src/nixos-anywhere.sh")
    text = p.read_text()
    before = 'runKexec() {\n  if [[ ''${isInstaller} == "y" ]]; then\n    return\n  fi\n'
    assert before in text
    p.write_text(text.replace(before, 'runKexec() {\n'))
    PYCODE
  '';
})

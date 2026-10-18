{ pkgs, packages }:
let
  runtime = packages.windowsEditorRuntime;
  # @cc [owner:ghuntley,label:verification;security] windows-editor-runtime-boundary
  # The Windows staging closure MUST expose the reviewed target and native
  # executable inventory, while its metadata MUST remain explicitly editor
  # false. No package-only check may mutate the retained windows-v1 image.
  check =
    assert runtime.passthru.targetPlatform == "win32-x64";
    assert runtime.passthru.runtimeOnly;
    assert runtime.passthru.editorCapability == false;
    true;
in
assert check;
pkgs.runCommand "windows-editor-runtime-check" { nativeBuildInputs = [ pkgs.jq pkgs.file ]; } ''
  manifest=${runtime}/overalls-editor-windows-runtime.json
  jq -e '.version == 1 and .target == "win32-x64" and .editor_capability == false and
    .node.path == "bin/node.exe" and .ripgrep.path == "bin/rg.exe" and
    (.node.sha256 | test("^[0-9a-f]{64}$")) and (.ripgrep.sha256 | test("^[0-9a-f]{64}$"))' "$manifest" >/dev/null
  test "$(sha256sum ${runtime}/bin/node.exe | cut -d' ' -f1)" = "$(jq -r .node.sha256 "$manifest")"
  test "$(sha256sum ${runtime}/bin/rg.exe | cut -d' ' -f1)" = "$(jq -r .ripgrep.sha256 "$manifest")"
  file ${runtime}/bin/node.exe | grep -q 'PE32+ executable.*MS Windows.*x86-64'
  file ${runtime}/bin/rg.exe | grep -q 'PE32+ executable.*MS Windows.*x86-64'
  test -s ${runtime}/licenses/node/LICENSE
  test -s ${runtime}/licenses/ripgrep/COPYING
  cat > "$out" <<'EOF'
windows-editor-runtime=win32-x64
editor-capability=false
EOF
''

{ pkgs, source }:
{ nativeBuild, narHash }:
let
  inputs = import ./inputs.nix;
  sourceDateEpoch = "1791274552";
  descriptor = {
    editor_protocol = source.editorProtocol;
    source_commit = source.sourceCommit;
    release_id = source.releaseId;
  };
in
# @cc [owner:ghuntley,label:build;security] windows-editor-native-bundle-pin
# A native Windows build MUST match the caller-reviewed recursive NAR hash and
# the exact source payload's release descriptor, contain no links or store
# references, and contain its native-build completion marker. Importing it MUST
# NOT promote the Windows editor capability or assert native browser acceptance.
# The closed provenance record MUST identify the fixed source, Node and build
# date plus bounded compiler/toolset versions and executable digests. This is
# recorded builder custody, not proof of a reproducible Windows compilation.
pkgs.runCommand "overalls-vscode-web-windows-native-bundle" {
  outputHashMode = "recursive";
  outputHash = narHash;
  outputHashAlgo = "sha256";
  allowedReferences = [ ];
  nativeBuildInputs = [ pkgs.jq pkgs.file ];
  passthru = {
    targetPlatform = "win32-x64";
    nativeBundle = true;
    editorCapability = false;
    inherit (source) editorProtocol sourceCommit releaseId;
    inherit descriptor;
  };
} ''
  test -d ${nativeBuild}
  if find ${nativeBuild} ! -type f ! -type d -print -quit | grep -q .; then
    echo "Windows native editor bundle contains a non-regular entry" >&2
    exit 1
  fi
  mkdir -p "$out"
  cp -R ${nativeBuild}/. "$out/"
  chmod -R u+w "$out"
  test "$(cat "$out/native-build-complete")" = 'editor_capability=false'
  jq -e --argjson expected '${builtins.toJSON descriptor}' '. == $expected' \
    "$out/overalls-editor-release.json" >/dev/null
  jq -e --arg release '${source.releaseId}' --argjson protocol '${toString source.editorProtocol}' \
    --arg commit '${source.sourceCommit}' \
    '.overallsEditor.releaseId == $release and .overallsEditor.protocol == $protocol and .commit == $commit' \
    "$out/product.json" >/dev/null
  # REH-web packaging stamps exactly these four fields in gulpfile.reh.ts.
  # Every product policy, gallery, signing-key, default and naming field must
  # otherwise equal the closed source payload, including absence of AI fields.
  jq --sort-keys 'del(.commit, .nlsMetadataHash, .date, .version)' \
    ${source}/source/product.json > expected-product.json
  jq --sort-keys 'del(.commit, .nlsMetadataHash, .date, .version)' \
    "$out/product.json" > actual-product.json
  cmp expected-product.json actual-product.json
  test "$(stat -c %s "$out/native-build-provenance.json")" -le 4096
  jq -e --arg commit '${source.sourceCommit}' --arg epoch '${sourceDateEpoch}' --arg node 'v${inputs.nodeVersion}' '
    def bounded_version:
      type == "string" and length >= 1 and length <= 128 and test("^[0-9A-Za-z][0-9A-Za-z ._()+-]*$");
    def sha256:
      type == "string" and test("^[0-9a-f]{64}$");
    keys == ["compiler", "compiler_sha256", "msbuild", "msbuild_sha256", "node", "source_commit", "source_date_epoch", "toolset", "version", "visual_studio"] and
    .version == 1 and .source_commit == $commit and .source_date_epoch == $epoch and .node == $node and
    ([.visual_studio, .toolset, .compiler, .msbuild] | all(bounded_version)) and
    ([.compiler_sha256, .msbuild_sha256] | all(sha256))
  ' "$out/native-build-provenance.json" >/dev/null
  test -s "$out/out/server-main.js"
  test -s "$out/bin/overalls-code.cmd"
  test -s "$out/product.json"
  cmp ${source}/source/LICENSE.txt "$out/LICENSE"
  cmp ${source}/source/ThirdPartyNotices.txt "$out/ThirdPartyNotices.txt"
  cmp ${./extensions.lock.json} "$out/overalls-editor-extensions.json"
  while IFS=$'\t' read -r identity version; do
    jq -e --arg id "$identity" --arg version "$version" \
      '((.publisher + "." + .name) | ascii_downcase) == ($id | ascii_downcase) and .version == $version' \
      "$out/extensions/$identity/package.json" >/dev/null
  done < <(jq -r '.extensions[] | [.id, .version] | @tsv' "$out/overalls-editor-extensions.json")
  file "$out/node.exe" > node-format
  grep -q 'PE32+ executable' node-format
  grep -q 'MS Windows' node-format
  grep -q 'x86-64' node-format
''

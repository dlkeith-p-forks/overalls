{ pkgs, editor, version, identity ? "personal" }:
let
  fixtureIdentity = if identity == "personal" then {
    name = "EditorConfig";
    publisher = "EditorConfig";
    versions = [ "0.18.1" "0.18.3" ];
  } else {
    name = "git";
    publisher = "vscode";
    versions = [ "100.0.0" ];
  };
  manifest = pkgs.writeText "${identity}-extension-fixture-package.json" (builtins.toJSON {
    inherit (fixtureIdentity) name publisher;
    inherit version;
    displayName = if identity == "personal" then "EditorConfig Personal Version Fixture" else "Core Builtin Refusal Fixture";
    engines.vscode = "^1.141.0";
    main = "./extension.js";
    extensionKind = [ "workspace" ];
  });
in
# @cc [owner:ghuntley,label:verification] fixture-local-personal-version-build
# Local lower/newer versions MUST be independent inert fixtures; the signed
# system extension bytes MUST NOT be rewritten to fabricate update evidence.
# The closed core identity MUST exercise only a refused native install.
assert builtins.isString identity && builtins.elem identity [ "personal" "core" ];
assert builtins.isString version && builtins.elem version fixtureIdentity.versions;
pkgs.stdenvNoCC.mkDerivation {
  pname = if identity == "personal" then "editorconfig-personal-version-fixture" else "core-builtin-refusal-fixture";
  inherit version;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.typescript pkgs.zip ];
  buildPhase = ''
    runHook preBuild
    mkdir -p extension
    cp ${./personal-extension.ts} extension.ts
    cp ${editor.src}/src/vscode-dts/vscode.d.ts vscode.d.ts
    tsc --strict --noUncheckedIndexedAccess --noEmitOnError --target ES2022 \
      --lib ES2022,DOM --module commonjs --outDir extension extension.ts vscode.d.ts
    cp ${manifest} extension/package.json
    chmod 0644 extension/package.json extension/extension.js
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    TZ=UTC touch -t 198001010000 extension/package.json extension/extension.js
    zip -X -q "$out/personal-version.vsix" extension/package.json extension/extension.js
    runHook postInstall
  '';
}

{ pkgs, editor }:
let
  manifest = pkgs.writeText "overalls-browser-fixture-package.json" (builtins.toJSON {
    name = "overalls-browser-fixture";
    publisher = "overalls";
    version = "0.0.1";
    displayName = "Overalls Browser Fixture";
    engines.vscode = "^1.141.0";
    browser = "./extension.js";
    activationEvents = [ "onCommand:overalls.browserFixture" ];
    contributes.commands = [{ command = "overalls.browserFixture"; title = "Overalls Fixture: Run Browser Extension"; }];
  });
in
# @cc [owner:ghuntley,label:verification] fixture-browser-extension-build
# WEB-only activation evidence MUST use a typed fixture built against the
# actual official editor API, without a native main entry or registry fetch.
pkgs.stdenvNoCC.mkDerivation {
  pname = "overalls-browser-fixture";
  version = "0.0.1";
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.typescript pkgs.zip ];
  buildPhase = ''
    runHook preBuild
    mkdir -p extension
    cp ${./web-extension.ts} extension.ts
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
    zip -X -q "$out/browser-fixture.vsix" extension/package.json extension/extension.js
    runHook postInstall
  '';
}

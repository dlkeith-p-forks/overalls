{ pkgs, editor }:
let
  aiCommands = [ "Chat" "Editor" "Quick" "Inline" "RestoreChat" "RestoreSession" "RestoreDebug" ];
  manifest = pkgs.writeText "overalls-native-fixture-package.json" (builtins.toJSON {
    name = "overalls-native-fixture";
    publisher = "overalls";
    version = "0.0.1";
    displayName = "Overalls Native Fixture";
    engines.vscode = "^1.141.0";
    main = "./extension.js";
    extensionKind = [ "workspace" ];
    activationEvents = [ "onCommand:overalls.nativePolicy" "onCommand:overalls.nativeDirenv" "onCommand:overalls.nativeOverrides" "onCommand:overalls.nativeDisabled" "onCommand:overalls.nativeRust" "onCommand:overalls.nativeElixir" "onCommand:overalls.nativeVersion" ]
      ++ map (name: "onCommand:overalls.nativeAI${name}") aiCommands;
    contributes = {
      commands = map (command: { command = "overalls.native${command}"; title = "Overalls Fixture: Native ${command}"; }) [ "Policy" "Direnv" "Overrides" "Disabled" "Rust" "Elixir" "Version" ]
        ++ map (name: { command = "overalls.nativeAI${name}"; title = "Overalls Fixture: Native AI ${name}"; }) aiCommands;
      languageModelTools = [{
        name = "overalls_fixture_tool";
        displayName = "Inert native fixture";
        modelDescription = "Isolated fixture that must never execute under disabled AI policy.";
        inputSchema = { type = "object"; properties = { }; additionalProperties = false; };
      }];
    };
  });
in
# @cc [owner:ghuntley,label:verification] fixture-native-extension-build
# The native policy fixture MUST compile against the pinned official editor API
# and enter the guest as a local test VSIX, without registry/runtime downloads.
pkgs.stdenvNoCC.mkDerivation {
  pname = "overalls-native-fixture";
  version = "0.0.1";
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.typescript pkgs.zip ];
  buildPhase = ''
    runHook preBuild
    mkdir -p extension
    cp ${./native-extension.ts} extension.ts
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
    zip -X -q "$out/native-fixture.vsix" extension/package.json extension/extension.js
    runHook postInstall
  '';
}

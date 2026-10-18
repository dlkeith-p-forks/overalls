{ pkgs, packages }:
let
  python = pkgs.python313.withPackages (p: [ p.playwright ]);
  manifest = pkgs.writeText "windows-native-acceptance-package.json" (builtins.toJSON {
    name = "windows-native-acceptance";
    publisher = "overalls";
    version = "0.0.1";
    displayName = "Overalls Windows Native Acceptance";
    engines.vscode = "^1.141.0";
    main = "./extension.js";
    extensionKind = [ "workspace" ];
    activationEvents = [ "onCommand:overalls.windowsAcceptance" ];
    contributes.commands = [{
      command = "overalls.windowsAcceptance";
      title = "Overalls Fixture: Windows Native Acceptance";
    }];
  });
in
# @cc [owner:ghuntley,label:verification] windows-editor-harness-is-not-native-evidence
# This artifact MUST compile the fixture against the pinned official editor API,
# type/lint-check its runnable controller and run input/refusal checks. Building
# it MUST NOT claim native Windows/browser acceptance or promote capability.
pkgs.stdenvNoCC.mkDerivation {
  pname = "overalls-windows-editor-acceptance-harness";
  version = "0.1.0";
  src = ./.;
  nativeBuildInputs = [ pkgs.typescript pkgs.ruff pkgs.ty pkgs.powershell pkgs.openssl pkgs.makeWrapper ];
  buildPhase = ''
    runHook preBuild
    export PYTHONDONTWRITEBYTECODE=1
    export RUFF_CACHE_DIR="$TMPDIR/ruff"
    cp ${../../../../../pyproject.toml} pyproject.toml
    cp ${packages.vscodeWeb.src}/src/vscode-dts/vscode.d.ts vscode.d.ts
    tsc --strict --noUncheckedIndexedAccess --noEmitOnError --target ES2022 \
      --lib ES2022,DOM --module commonjs --outDir compiled extension.ts vscode.d.ts
    cp ${manifest} compiled/package.json
    ruff format --check .
    ruff check .
    ty check --python ${python}/bin/python3 --python-version 3.13 browser.py relay.py test_boundary.py
    ${python}/bin/python3 -m unittest -v test_boundary
    pwsh -NoLogo -NoProfile -NonInteractive -Command \
      '$tokens=$null; $errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-Location) "control.ps1"), [ref]$tokens, [ref]$errors); if ($errors.Count -ne 0) { throw "windows_editor_fixture_parse_failed" }'
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/windows-editor" "$out/bin"
    cp browser.py relay.py control.ps1 README.md compiled/extension.js compiled/package.json "$out/share/windows-editor/"
    makeWrapper ${python}/bin/python3 "$out/bin/windows-editor-acceptance" \
      --add-flags "$out/share/windows-editor/browser.py" \
      --set WINDOWS_EDITOR_CHROMIUM ${pkgs.chromium}/bin/chromium \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.openssh pkgs.openssl ]}
    runHook postInstall
  '';
}

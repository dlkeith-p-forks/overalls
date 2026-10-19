{ pkgs
, extensionsGallery ? {
    serviceUrl = "https://open-vsx.org/vscode/gallery";
    itemUrl = "https://open-vsx.org/vscode/item";
    resourceUrlTemplate = "https://open-vsx.org/vscode/unpkg/{publisher}/{name}/{version}/{path}";
  }
, extensionSigningKeys ? [ (builtins.readFile ./open-vsx-key.pem) ]
}:
let
  inherit (pkgs) lib;
  inputs = import ./inputs.nix;
  nodejs = import ./node-runtime.nix { inherit pkgs; };
  browserPython = pkgs.python313.withPackages (packages: [ packages.playwright ]);
  browserFontConfig = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  directories = builtins.fromJSON (builtins.readFile ./npm-directories.json);
  extensionLock = builtins.fromJSON (builtins.readFile ./extensions.lock.json);
  baselineIds = [ "EditorConfig.EditorConfig" "cab404.vscode-direnv" "elixir-lsp.elixir-ls" "rust-lang.rust-analyzer" ];
  patchStack = [ ./patches/0001-overalls-browser-editor.patch ./patches/0002-overalls-editor-policy.patch ./patches/0003-overalls-startup-defaults.patch ./patches/0004-overalls-personal-bundled-updates.patch ];
  # @cc [owner:ghuntley,label:product] editor-personal-bundle-update-roster
  # Only the four locked third-party defaults MUST gain personal update paths.
  # The forced-auto-update roster MUST remain empty; core builtin guards and
  # ordinary personal update preferences MUST retain their upstream behavior.
  userUpdatableBundledExtensions = map lib.toLower baselineIds;
  languageAdapters = pkgs.runCommand "overalls-editor-project-language-adapters" { } ''
    mkdir -p "$out"
    cp ${./project-language-adapters}/*.sh "$out/"
    chmod 0555 "$out/"*.sh
    patchShebangs "$out"
  '';
  editorPolicy = { builtInAI = "disabled"; workspaceTrust = "disabled"; };
  maintenanceKeyFiles = map (key: pkgs.writeText "overalls-editor-signing-key.pem" key) extensionSigningKeys;
  configurationDefaults = {
    "rust-analyzer.server.path" = "rust-analyzer";
    "elixirLS.languageServerOverridePath" = toString languageAdapters;
    "workbench.startupEditor" = "none";
    "workbench.welcomePage.walkthroughs.openOnInstall" = false;
  };
  productConfiguration = {
    nameShort = "Overalls Code";
    nameLong = "Overalls Code";
    applicationName = "overalls-code";
    serverApplicationName = "overalls-code";
    dataFolderName = ".overalls-code";
    serverDataFolderName = ".overalls-code-server";
    urlProtocol = "overalls-code";
    quality = "stable";
    enableTelemetry = false;
    builtInExtensions = [ ];
    webBuiltInExtensions = [ ];
    builtInExtensionsEnabledWithAutoUpdates = [ ];
    trustedExtensionAuthAccess = { };
    inherit extensionsGallery;
  };
  # @cc [owner:ghuntley,label:build] editor-release-input-identity
  # The release MUST bind the source, all patches, trust keys, product options,
  # native runtime, dependency hashes and maintained build recipe.
  releaseId = builtins.hashString "sha256" (builtins.toJSON {
    inherit inputs productConfiguration extensionSigningKeys editorPolicy configurationDefaults userUpdatableBundledExtensions;
    extensionLock = builtins.hashFile "sha256" ./extensions.lock.json;
    extensionValidation = builtins.hashFile "sha256" ./extensions.py;
    maintenanceEntry = builtins.hashFile "sha256" ./maintenance-entry.ts;
    maintenanceValidator = builtins.hashFile "sha256" ./check-extension.mts;
    policyCheck = builtins.hashFile "sha256" ./check-policy.mts;
    bundledUpdateCheck = builtins.hashFile "sha256" ./check-bundled-updates.mts;
    patches = map (patch: builtins.hashFile "sha256" patch) patchStack;
    recipe = builtins.hashFile "sha256" ./default.nix;
    nodeRuntimeRecipe = builtins.hashFile "sha256" ./node-runtime.nix;
    npmDirectories = builtins.hashFile "sha256" ./npm-directories.json;
    runtimeCheck = builtins.hashFile "sha256" ./check-runtime.mts;
    accountCheck = builtins.hashFile "sha256" ./check-no-account.mts;
    browserCheck = builtins.hashFile "sha256" ./check-browser.py;
    browserCheckTools = map toString [ browserPython pkgs.chromium pkgs.openssl browserFontConfig ];
    nativeRuntime = map toString [ nodejs pkgs.ripgrep pkgs.libsecret pkgs.libkrb5
      pkgs.libx11 pkgs.libxkbfile pkgs.stdenv.cc.cc.lib ];
    buildToolchain = map toString [ pkgs.stdenv pkgs.stdenv.cc pkgs.python3
      pkgs.pkg-config pkgs.makeWrapper pkgs.git pkgs.jq pkgs.autoPatchelfHook ];
  });
  productOverlay = pkgs.writeText "overalls-editor-product.json" (builtins.toJSON
    (productConfiguration // {
      overallsEditor = {
        inherit releaseId extensionSigningKeys configurationDefaults userUpdatableBundledExtensions;
        policy = editorPolicy;
        protocol = 1;
      };
    }));
  descriptor = pkgs.writeText "overalls-editor-release.json" (builtins.toJSON {
    source_commit = inputs.sourceCommit;
    editor_protocol = 1;
    release_id = releaseId;
  });
  npmCache = import ./npm-cache.nix { inherit pkgs; };
  electronTypes = pkgs.fetchurl {
    url = "https://github.com/electron/electron/releases/download/v${inputs.electronTypesVersion}/electron.d.ts";
    hash = inputs.electronTypesHash;
  };
in
assert nodejs.version == inputs.nodeVersion;
assert lib.assertMsg (pkgs.stdenv.hostPlatform.system == "x86_64-linux") "The reviewed editor target is x86_64-linux";
assert lib.assertMsg (extensionLock.version == 1
  && lib.sort builtins.lessThan (map (extension: extension.id) extensionLock.extensions) == baselineIds
  && lib.all (extension: extension.targetPlatform == "universal") extensionLock.extensions)
  "The editor baseline MUST contain exactly the four reviewed universal extensions";
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = "overalls-vscode-web";
  inherit (inputs) version;
  src = pkgs.fetchFromGitHub {
    owner = "microsoft";
    repo = "vscode";
    rev = inputs.sourceCommit;
    hash = inputs.sourceHash;
  };
  patches = patchStack;
  nativeBuildInputs = [ nodejs pkgs.python3 pkgs.pkg-config pkgs.makeWrapper pkgs.git pkgs.jq pkgs.autoPatchelfHook ];
  buildInputs = [ pkgs.libsecret pkgs.libkrb5 pkgs.libx11 pkgs.libxkbfile pkgs.stdenv.cc.cc.lib ];
  env = {
    BUILD_SOURCEVERSION = inputs.sourceCommit;
    SOURCE_DATE_EPOCH = "1791274552";
    NODE_ENV = "development";
    NODE_OPTIONS = "--max-old-space-size=16384";
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
    NIX_NODEJS_BUILDNPMPACKAGE = "1";
    npm_config_nodedir = nodejs;
    npm_config_node_gyp = "${nodejs}/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js";
    npm_config_offline = "true";
    npm_config_progress = "false";
    npm_config_runtime = "node";
    npm_config_target = inputs.nodeVersion;
    npm_config_build_from_source = "true";
  };
  postPatch = ''
    jq --slurp '(.[0] | del(.trustedExtensionAuthAccess)) * .[1] | del(.defaultChatAgent, .voiceWsUrl, .webviewContentExternalBaseUrlTemplate, .agentsTelemetryAppName)' \
      product.json ${productOverlay} > product.overalls.json
    mv product.overalls.json product.json
    substituteInPlace remote/.npmrc --replace-fail 'target="24.21.0"' 'target="${inputs.nodeVersion}"'
    mkdir -p .build/node/v${inputs.nodeVersion}/linux-x64
    ln -s ${nodejs}/bin/node .build/node/v${inputs.nodeVersion}/linux-x64/node
    cp LICENSE.txt remote/LICENSE
    mkdir -p .build/typings
    cp ${electronTypes} .build/typings/electron.d.ts
  '';
  configurePhase = ''
    runHook preConfigure
    cp -R ${npmCache} "$TMPDIR/npm-cache"
    chmod -R +w "$TMPDIR/npm-cache"
    export npm_config_devdir="$TMPDIR/node-gyp"
    ${lib.concatMapStringsSep "\n" (directory: ''
      (
        cd ${lib.escapeShellArg directory}
        npm_config_cache="$TMPDIR/npm-cache/${directory}" npm ci --ignore-scripts --no-audit --no-fund
        patchShebangs node_modules
      )
    '') directories}
    # No optional agent SDK/backend is shipped or started.
    jq 'del(.dependencies["@github/copilot-sdk"], .dependencies["@vscode/copilot-api"], .dependencies["@microsoft/mxc-sdk"], .copilotRuntimeVersion)' remote/package.json > remote/package.overalls.json
    mv remote/package.overalls.json remote/package.json
    npm_config_cache="$TMPDIR/npm-cache/remote" npm --prefix remote prune --ignore-scripts --no-audit --no-fund
    # Ripgrep is a source-built Nix input; npm MUST NOT fetch a binary.
    find . -path '*/node_modules/@vscode/ripgrep-universal' -type d -print0 |
      while IFS= read -r -d $'\0' directory; do
        mkdir -p "$directory/bin/linux-x64"
        ln -sf ${pkgs.ripgrep}/bin/rg "$directory/bin/rg"
        ln -sf ${pkgs.ripgrep}/bin/rg "$directory/bin/linux-x64/rg"
      done
    # Only build executables run here; optional AI/auth platform binaries in
    # the development tree are not runtime inputs and MUST NOT be loaded.
    autoPatchelf node_modules/@typescript/typescript-linux-x64
    npm_config_cache="$TMPDIR/npm-cache/remote" npm --prefix remote rebuild --build-from-source --no-audit --no-fund
    # Source-built native bindings are the only watcher/PTY runtime inputs.
    rm -rf remote/node_modules/@parcel/watcher-* remote/node_modules/node-pty/prebuilds
    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild
    cp ${./maintenance-entry.ts} overalls-maintenance-entry.ts
    jq '.include += ["../overalls-maintenance-entry.ts"] | .compilerOptions.rootDir = ".."' src/tsconfig.json > src/tsconfig.overalls-maintenance.json
    npm run typecheck-client -- --project ./src/tsconfig.overalls-maintenance.json
    node node_modules/typescript/bin/tsc6 --noEmit --strict --skipLibCheck --target es2022 --module nodenext --types node --typeRoots ./node_modules/@types ${./check-patches.mts}
    node node_modules/typescript/bin/tsc6 --noEmit --strict --skipLibCheck --target es2022 --module nodenext --types node --typeRoots ./node_modules/@types ${./check-runtime.mts}
    node node_modules/typescript/bin/tsc6 --noEmit --strict --skipLibCheck --target es2022 --module nodenext --types node --typeRoots ./node_modules/@types ${./check-no-account.mts}
    node node_modules/typescript/bin/tsc6 --noEmit --strict --skipLibCheck --target es2022 --module nodenext --types node --typeRoots ./node_modules/@types ${./check-extension.mts}
    node node_modules/typescript/bin/tsc6 --noEmit --strict --skipLibCheck --target es2022 --module nodenext --types node --typeRoots ./node_modules/@types ${./check-policy.mts}
    node node_modules/typescript/bin/tsc6 --noEmit --strict --skipLibCheck --target es2022 --module nodenext --types node --typeRoots ./node_modules/@types ${./check-bundled-updates.mts}
    build/node_modules/.bin/esbuild src/vs/platform/extensionManagement/common/overallsBundledExtensions.ts --bundle --platform=node --format=esm --outfile="$TMPDIR/overalls-bundled-updates-check.mjs"
    node ${./check-bundled-updates.mts} "$TMPDIR/overalls-bundled-updates-check.mjs"
    build/node_modules/.bin/esbuild src/vs/platform/configuration/test/common/overallsProductPolicy.check.ts --bundle --platform=node --format=esm --outfile="$TMPDIR/overalls-policy-check.mjs"
    build/node_modules/.bin/esbuild src/vs/workbench/contrib/chat/test/common/overallsProductPolicy.check.ts --bundle --platform=node --format=esm --outfile="$TMPDIR/overalls-service-check.mjs"
    node ${./check-policy.mts} "$TMPDIR/overalls-policy-check.mjs" "$TMPDIR/overalls-service-check.mjs"
    build/node_modules/.bin/esbuild overalls-maintenance-entry.ts --bundle --platform=node --format=esm --packages=external --outfile="$TMPDIR/maintenance.bundle.mjs"
    build/node_modules/.bin/esbuild src/vs/workbench/services/accounts/browser/defaultAccount.ts --bundle --platform=node --format=esm --outfile="$TMPDIR/overalls-default-account.mjs"
    node ${./check-no-account.mts} "$TMPDIR/overalls-default-account.mjs"
    npm run gulp vscode-reh-web-linux-x64-min
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -R ../vscode-reh-web-linux-x64/. "$out/"
    ln -sf ${nodejs}/bin/node "$out/node"
    mkdir -p "$out/bin"
    rm -f "$out/bin/overalls-code"
    makeWrapper ${nodejs}/bin/node "$out/bin/overalls-code" --add-flags "$out/out/server-main.js"
    cp ${descriptor} "$out/overalls-editor-release.json"
    cp LICENSE.txt "$out/LICENSE.txt"
    cp ThirdPartyNotices.txt "$out/ThirdPartyNotices.txt"
    mkdir -p "$out/lib/overalls-maintenance"
    cp "$TMPDIR/maintenance.bundle.mjs" "$out/lib/overalls-maintenance/maintenance.bundle.mjs"
    cp ${./check-extension.mts} "$out/lib/overalls-maintenance/check-extension.mts"
    ${lib.concatMapStringsSep "\n" (extension:
      let
        vsix = pkgs.fetchurl { inherit (extension.vsix) url hash; };
        signature = pkgs.fetchurl { inherit (extension.signature) url hash; };
      in ''
        ${pkgs.python313}/bin/python3 ${./extensions.py} extract \
          --lock ${./extensions.lock.json} --id ${lib.escapeShellArg extension.id} \
          --vsix ${vsix} --signature ${signature} \
          --node ${nodejs}/bin/node --validator "$out/lib/overalls-maintenance/check-extension.mts" \
          ${lib.concatMapStringsSep " " (key: "--key " + lib.escapeShellArg (toString key)) maintenanceKeyFiles} \
          --editor-version ${inputs.version} --output "$out/extensions/${extension.id}"
      '') extensionLock.extensions}
    cp ${./extensions.lock.json} "$out/overalls-editor-extensions.json"
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    FONTCONFIG_FILE=${browserFontConfig} node ${./check-runtime.mts} "$out" ${browserPython}/bin/python3 ${pkgs.chromium}/bin/chromium ${./check-browser.py} ${pkgs.openssl}/bin/openssl
    runHook postInstallCheck
  '';
  passthru = {
    sourceCommit = inputs.sourceCommit;
    editorProtocol = 1;
    inherit releaseId languageAdapters maintenanceKeyFiles;
    extensionIds = baselineIds;
    descriptorRelative = "overalls-editor-release.json";
    assetRootRelative = "out/vs/workbench/contrib/webview/browser/pre";
    assets = finalAttrs.finalPackage;
  };
  meta = {
    description = "Source-built Code OSS browser workbench for a Overalls guest";
    homepage = "https://github.com/microsoft/vscode";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "overalls-code";
  };
})

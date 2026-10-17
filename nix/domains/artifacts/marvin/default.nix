{ pkgs }:
let
  inherit (pkgs) lib;
  source = lib.cleanSourceWith {
    src = ../../../../marvin;
    filter = path: type:
      let name = builtins.baseNameOf path;
      in name != "dist" && name != "node_modules" &&
        (type == "directory" || lib.hasSuffix ".mjs" name || lib.hasSuffix ".json" name ||
          lib.hasSuffix ".d.ts" name || lib.hasSuffix ".html" name || lib.hasSuffix ".css" name ||
          name == "CONTRACTS" || name == "README.md");
  };
  version = (builtins.fromJSON (builtins.readFile ../../../../marvin/package.json)).version;
  npmDeps = pkgs.fetchNpmDeps {
    name = "overalls-marvin-${version}-npm-deps";
    src = source;
    hash = "sha256-LnzKLOxg5uIuNnDI1xGqEGFx0dQ8MCOT4FodqsqGpBo=";
  };
  common = {
    pname = "overalls-marvin";
    inherit version npmDeps;
    src = source;
    npmFlags = [ "--ignore-scripts" ];
    npmConfigIgnoreScripts = true;
    dontNpmPrune = true;
    dontNpmBuild = true;
    SOURCE_DATE_EPOCH = "315532800";
  };
  tests = pkgs.buildNpmPackage (common // {
    pname = "overalls-marvin-check";
    nativeBuildInputs = [ pkgs.chromium pkgs.unzip ];
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
    buildPhase = ''
      runHook preBuild
      export CHROME="${lib.getExe pkgs.chromium}"
      npm run check
      npm run smoke:chrome
      unzip -t dist/bin/chrome.zip
      unzip -t dist/bin/firefox.xpi
      runHook postBuild
    '';
    installPhase = ''touch "$out"'';
  });
in
pkgs.buildNpmPackage (common // {
  # @cc [owner:ghuntley,label:build] marvin-reproducible-release
  # The release MUST use package.json's version and the same fixed source epoch
  # for both archives. Source provenance MUST cover maintained Marvin inputs.
  buildPhase = ''
    runHook preBuild
    npm run typecheck
    npm run build
    npm run package
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share/overalls-marvin"
    cp dist/bin/chrome.zip dist/bin/firefox.xpi "$out/bin/"
    cp dist/manifest.json "$out/manifest.json"
    cp -r dist/chrome dist/firefox "$out/share/overalls-marvin/"
    runHook postInstall
  '';
  passthru = { inherit tests; };
  meta = {
    description = "Unsigned Overalls Chrome and Firefox repository launcher extensions";
    platforms = [ "x86_64-linux" ];
  };
})

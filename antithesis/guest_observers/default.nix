{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "overalls-antithesis-terminal-probe";
  version = "1";
  src = ./probe.rs;
  dontUnpack = true;
  dontConfigure = true;
  strictDeps = true;
  nativeBuildInputs = [ pkgs.rustc ];
  buildPhase = ''
    runHook preBuild
    rustc --edition=2021 -O -o overalls-terminal-probe "$src"
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm0755 overalls-terminal-probe "$out/bin/overalls-terminal-probe"
    runHook postInstall
  '';
  meta.platforms = [ "x86_64-linux" ];
}

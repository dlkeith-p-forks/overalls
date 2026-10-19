# @cc [owner:ghuntley,label:verification] libhegel-dart-pin
# The pub.dev hegel package binds the engine release it pins (0.33.x), not the
# hegel-rust build in ./libhegel.nix. The engine MUST come from that release
# by the same SHA-256 the package checks in `lib/src/libhegel/version.g.dart`;
# Mila's pubspec user-define points the build hook at this store path so no
# check downloads anything.
{ pkgs }:
let
  version = "0.33.0";
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "libhegel-dart";
  inherit version;
  src = pkgs.fetchurl {
    url = "https://github.com/hegeldev/hegel-rust/releases/download/v${version}/libhegel-linux-amd64.so";
    sha256 = "9a14df0a6259ce83426e4015ce02d376b938323f7c210bab90b86bfbca970406";
  };
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.autoPatchelfHook ];
  buildInputs = [ pkgs.stdenv.cc.cc.lib ];
  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/lib/libhegel.so
    runHook postInstall
  '';
  passthru.expectedVersion = version;
  meta = {
    description = "Hegel property-testing engine release pinned by the Dart hegel package";
    homepage = "https://hegel.dev";
    license = pkgs.lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}

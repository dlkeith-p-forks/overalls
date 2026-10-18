{ lib, rustPlatform, fetchFromGitHub, makeWrapper }:
rustPlatform.buildRustPackage rec {
  pname = "underclass";
  version = "0.1.0-7169223";

  src = fetchFromGitHub {
    owner = "ghuntley";
    repo = "underclass";
    rev = "7169223709693504882d0f7c3d2f34660682c936";
    hash = "sha256-4a4Iy4zQnTc92GHzk3nVLk93S/1HXbXuS46JyirorAQ=";
  };

  cargoHash = "sha256-trXMnTioYNjr74HjFcDjMvJ8GYUG0UTiPVi68PNBzEk=";
  # @cc [owner:ghuntley,label:durability;build] underclass-fixed-slo-journal
  # The pinned proxy MUST compile the reviewed Rust journal and admission/body
  # patch from this source tree without adding dependencies or provider replay.
  patches = [ ./instrumentation.patch ];
  postPatch = ''
    cp ${./slo.rs} src/slo.rs
  '';
  nativeBuildInputs = [ makeWrapper ];
  # @cc [owner:ghuntley,label:cli] underclass-utop-wrapper
  # The package MUST expose utop as underclass top, preserving user arguments.
  postInstall = ''
    makeWrapper "$out/bin/underclass" "$out/bin/utop" --add-flags top
  '';
  # Hegel's build script launches a nested Cargo build that cannot use the
  # outer vendored registry. Upstream Rust tests run before revising this pin;
  # the fleet derivation and NixOS check remain fully offline.
  doCheck = false;

  meta = {
    description = "Pooled ChatGPT Codex and GitHub Copilot subscription proxy";
    homepage = "https://github.com/ghuntley/underclass";
    license = lib.licenses.mit;
    mainProgram = "underclass";
    platforms = [ "x86_64-linux" ];
  };
}

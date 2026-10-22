{ lib, rustPlatform, fetchFromGitHub, makeWrapper }:
rustPlatform.buildRustPackage rec {
  pname = "underclass";
  version = "0.1.0-c58a972";

  src = fetchFromGitHub {
    owner = "ghuntley";
    repo = "underclass";
    rev = "c58a9728430f6f21937f99b6f27de2978743104a";
    hash = "sha256-7AffzztgmcGLAK/ibIibUA8oXmbBCZw9xH7f5H9T4hc=";
  };

  cargoHash = "sha256-trXMnTioYNjr74HjFcDjMvJ8GYUG0UTiPVi68PNBzEk=";
  # Name the vendored crates without the version: the fixed-output path then
  # survives pin bumps that keep Cargo.lock, instead of refetching ~300 crates.
  cargoDepsName = pname;
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

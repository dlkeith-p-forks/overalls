{ pkgs }:
let
  inherit (pkgs) lib;
  rustVersion = "1.97.1";
  source = lib.cleanSourceWith {
    src = ../../lyra;
    filter = path: type:
      let name = builtins.baseNameOf path;
        # Shared WorkspaceSource vectors (ADR-0128) are read by `cargo test`.
        fixture = lib.hasSuffix ".json" name && lib.hasSuffix "/tests/fixtures" (builtins.dirOf (toString path));
      in name != "target" && name != ".hegel" && (type == "directory" || fixture || lib.hasSuffix ".rs" name || builtins.elem name [ "Cargo.toml" "Cargo.lock" "CONTRACTS" ]);
  };
  vendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "lyra-vendor";
    src = source;
    hash = "sha256-fpoIYFrL/iG4jeInD5Db6sY5RUMw/U37SCOdtytajrI=";
  };
  rustStd = target: hash: pkgs.fetchurl {
    url = "https://static.rust-lang.org/dist/rust-std-${rustVersion}-${target}.tar.xz";
    inherit hash;
  };
  targets = {
    "x86_64-unknown-linux-gnu" = rustStd "x86_64-unknown-linux-gnu" "sha256-HB5wSugBJrfeNPcuooJff9AXNt7CBzL67Uc3S5UoL7o=";
    "x86_64-unknown-linux-musl" = rustStd "x86_64-unknown-linux-musl" "sha256-UdgxeGgFVvc6X6ithlt2of9UGGdEXAD8ZdxnJGvC3mY=";
    "aarch64-unknown-linux-musl" = rustStd "aarch64-unknown-linux-musl" "sha256-Sf8IedlOLo6G1ehesVqSFZQ+jHi1E2PWVTRDWYyrXTE=";
    "x86_64-apple-darwin" = rustStd "x86_64-apple-darwin" "sha256-D6eGUwI75b3+tBntyC47E0bMqiPqoDZJHM4IQQHHQd0=";
    "aarch64-apple-darwin" = rustStd "aarch64-apple-darwin" "sha256-pIlfXGmV6DyrhofkaxQyRZI5gEne9xznXKMIyYHPIA0=";
    "x86_64-pc-windows-gnu" = rustStd "x86_64-pc-windows-gnu" "sha256-UT7Uh11aNybQLFhyA08Gc1k640PqYqcJOSE+iUwnS+M=";
    # Native firmware guests use the target's libc ABI. These archives are
    # type-check inputs; cargo-zigbuild supplies the cross linker at release.
    "x86_64-unknown-freebsd" = rustStd "x86_64-unknown-freebsd" "sha256-ney5I8TysfxX0tyzmoyclvkbHeWGq/N8/i257fRTDUM=";
    "x86_64-unknown-illumos" = rustStd "x86_64-unknown-illumos" "sha256-Eo74pjuHPaccqvpbF2FzDB1vUk4nElO/CFKhMJ7/o0A=";
  };
  rustcArchive = pkgs.fetchurl {
    url = "https://static.rust-lang.org/dist/rustc-${rustVersion}-x86_64-unknown-linux-gnu.tar.xz";
    hash = "sha256-mBnQoy1WvTOVhTGcgCYOMyd59VQf1mg4q34BbWyBSBk=";
  };
  toolchain = pkgs.stdenvNoCC.mkDerivation {
    pname = "lyra-rust-toolchain";
    version = rustVersion;
    dontUnpack = true;
    dontStrip = true;
    nativeBuildInputs = with pkgs; [ autoPatchelfHook gnutar xz ];
    buildInputs = with pkgs; [ stdenv.cc.cc.lib zlib libxml2 ];
    installPhase = ''
      mkdir -p "$out" "$TMPDIR/rust-dist"
      tar -xJf ${rustcArchive} -C "$TMPDIR/rust-dist"
      cp -a "$TMPDIR/rust-dist/rustc-1.97.1-x86_64-unknown-linux-gnu/rustc/." "$out/"
      chmod u+w "$out/lib/rustlib"
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (target: archive: ''
        tar -xJf ${archive} -C "$TMPDIR/rust-dist"
        cp -a "$TMPDIR/rust-dist/rust-std-1.97.1-${target}/rust-std-${target}/lib/rustlib/${target}" "$out/lib/rustlib/"
      '') targets)}
    '';
  };
  sdk = pkgs.fetchurl {
    url = "https://github.com/joseluisq/macosx-sdks/releases/download/11.3/MacOSX11.3.sdk.tar.xz";
    hash = "sha256-mtwTc9OHnhlz0orZ8XyQUbApMWdKPsKiSYEomJ7OLLE=";
  };
  # @cc [owner:ghuntley,label:build;verification] lyra-native-tls-check-toolchain
  # The sandboxed Lyra check MUST supply the build tools required by its
  # vendored Linux OpenSSL backend and run tests without network downloads, and
  # MUST type-check the crate for `x86_64-pc-windows-gnu` so Unix-only code
  # cannot creep into the shared modules the Windows agents link.
  tests = pkgs.stdenv.mkDerivation {
    pname = "lyra-tests";
    version = "0.1.0";
    src = source;
    # git: tests/workspace_object_format.rs drives the production clone plan
    # against a real repository.
    nativeBuildInputs = with pkgs; [ cargo rustc clippy openssh openssl perl util-linux git ];
    dontConfigure = true;
    buildPhase = ''
      export HOME="$TMPDIR/home"
      export CARGO_HOME="$TMPDIR/cargo-home"
      export OVERALLS_SSH_CA_BUNDLE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      mkdir -p "$HOME" "$CARGO_HOME"
      substitute ${vendor}/.cargo/config.toml "$CARGO_HOME/config.toml" --subst-var-by vendor "${vendor}"
      cargo test --locked --offline
      cargo clippy --all-targets --offline -- -D warnings
      # Windows guest agents: type-check the shared library and every Windows
      # bin for x86_64-pc-windows-gnu with the pinned toolchain (no linking, so
      # zig is not needed here). The Linux-only bins are not built for Windows.
      RUSTC="${toolchain}/bin/rustc" CARGO_TARGET_DIR="$TMPDIR/windows-check" \
        cargo check --locked --offline --target x86_64-pc-windows-gnu --lib --bin overalls \
          ${lib.concatMapStringsSep " " (binary: "--bin ${binary}") windowsBinaries}
      # Native guest daemons are checked with the same vendored dependencies;
      # this catches accidental Linux `/proc` or systemd coupling before an
      # image can claim FreeBSD/illumos agent support.
      for target in x86_64-unknown-freebsd x86_64-unknown-illumos; do
        RUSTC="${toolchain}/bin/rustc" CARGO_TARGET_DIR="$TMPDIR/native-$target" \
          cargo check --locked --offline --target "$target" \
            --lib ${lib.concatMapStringsSep " " (binary: "--bin ${binary}") nativeBinaries}
      done
    '';
    installPhase = ''
      touch "$out"
    '';
  };
  windowsBinaries = [
    "overalls-winprobe"
    "overalls-readinessd"
    "overalls-trustd-windows"
    "overalls-ssh-sync-windows"
    "overalls-host-certificate-windows"
    "overalls-workspaced-windows"
    "overalls-agentd-windows"
  ];
  nativeBinaries = [
    "overalls-native-readinessd"
    "overalls-native-trustd"
    "overalls-native-workspaced"
  ];
  # @cc [owner:ghuntley,label:build;guest] lyra-windows-cross-build
  # Windows guest agents MUST be cross-built from the shared Lyra crate for
  # `x86_64-pc-windows-gnu` with the pinned toolchain and vendored dependency
  # set used by the Linux build, without network access; every produced
  # `.exe` MUST stay at or below 100 MiB and MUST be listed with its SHA-256 in
  # the output manifest so the image builder can pin what it ships.
  windows = pkgs.stdenv.mkDerivation {
    pname = "lyra-windows";
    version = "0.1.0";
    allowedReferences = [ ];
    src = source;
    strictDeps = true;
    dontStrip = true;
    nativeBuildInputs = with pkgs; [ cargo cargo-zigbuild zig jq coreutils gnutar xz perl ];
    dontConfigure = true;
    doCheck = false;
    buildPhase = ''
      runHook preBuild
      export CARGO_HOME="$TMPDIR/cargo-home"
      export RUSTC="${toolchain}/bin/rustc"
      export CARGO_ZIGBUILD_CACHE_DIR="$TMPDIR/cargo-zigbuild-cache"
      export XDG_CACHE_HOME="$TMPDIR/cache"
      mkdir -p "$CARGO_HOME"
      substitute ${vendor}/.cargo/config.toml "$CARGO_HOME/config.toml" --subst-var-by vendor "${vendor}"
      export CARGO_TARGET_DIR="$TMPDIR/target"
      # Panic locations would otherwise embed vendored-crate store paths in the
      # executables, and the Windows disk image would keep them alive.
      export RUSTFLAGS="--remap-path-prefix=${vendor}=/vendor --remap-path-prefix=$PWD=/source"
      for binary in ${lib.concatStringsSep " " windowsBinaries}; do
        cargo zigbuild --release --locked --offline --target x86_64-pc-windows-gnu --bin "$binary"
      done
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      for binary in ${lib.concatStringsSep " " windowsBinaries}; do
        cp "$CARGO_TARGET_DIR/x86_64-pc-windows-gnu/release/$binary.exe" "$out/bin/$binary.exe"
        test "$(stat -c %s "$out/bin/$binary.exe")" -le 104857600
      done
      ${pkgs.python3}/bin/python3 - "$out" ${lib.concatStringsSep " " windowsBinaries} <<'PY'
import hashlib
import json
import pathlib
import sys

root: pathlib.Path = pathlib.Path(sys.argv[1])
names: list[str] = sys.argv[2:]
artifacts: dict[str, dict[str, str | int]] = {
    name: {
        "path": "/bin/" + name + ".exe",
        "sha256": hashlib.sha256((root / "bin" / (name + ".exe")).read_bytes()).hexdigest(),
        "bytes": (root / "bin" / (name + ".exe")).stat().st_size,
    }
    for name in names
}
(root / "manifest.json").write_text(json.dumps({"version": "0.1.0", "artifacts": artifacts}, sort_keys=True))
PY
      runHook postInstall
    '';
    meta = {
      description = "Lyra guest agents for Windows guests";
      platforms = [ "x86_64-linux" ];
    };
  };
in
pkgs.stdenv.mkDerivation {
  pname = "lyra";
  version = "0.1.0";
  src = source;
  strictDeps = true;
  dontStrip = true;
  nativeBuildInputs = with pkgs; [ cargo cargo-zigbuild zig jq coreutils gnutar xz perl ];
  dontConfigure = true;
  doCheck = false;
  buildPhase = ''
    runHook preBuild
    export CARGO_HOME="$TMPDIR/cargo-home"
    export RUSTC="${toolchain}/bin/rustc"
    export CARGO_ZIGBUILD_CACHE_DIR="$TMPDIR/cargo-zigbuild-cache"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    mkdir -p "$CARGO_HOME"
    substitute ${vendor}/.cargo/config.toml "$CARGO_HOME/config.toml" --subst-var-by vendor "${vendor}"
    tar -xJf ${sdk} -C "$TMPDIR"
    export SDKROOT="$TMPDIR/MacOSX11.3.sdk"
    export CARGO_TARGET_DIR="$TMPDIR/target"
    for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-apple-darwin aarch64-apple-darwin x86_64-pc-windows-gnu; do
      cargo zigbuild --release --locked --offline --target "$target" --bin overalls
    done
    cargo zigbuild --release --locked --offline --target x86_64-unknown-linux-musl --bin overalls-ssh-authorize
    cargo zigbuild --release --locked --offline --target x86_64-unknown-linux-musl --bin overalls-host-certificate
    cargo zigbuild --release --locked --offline --target x86_64-unknown-linux-musl --bin overalls-trustd
    cargo zigbuild --release --locked --offline --target x86_64-unknown-linux-musl --bin overalls-workspaced
    for target in x86_64-unknown-freebsd x86_64-unknown-illumos; do
      for binary in ${lib.concatStringsSep " " nativeBinaries}; do
        cargo zigbuild --release --locked --offline --target "$target" --bin "$binary"
      done
    done
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    cp "$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/release/overalls" "$out/bin/linux-amd64"
    cp "$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/release/overalls-ssh-authorize" "$out/bin/overalls-ssh-authorize"
    cp "$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/release/overalls-host-certificate" "$out/bin/overalls-host-certificate"
    cp "$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/release/overalls-trustd" "$out/bin/overalls-trustd"
    cp "$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/release/overalls-workspaced" "$out/bin/overalls-workspaced"
    cp "$CARGO_TARGET_DIR/aarch64-unknown-linux-musl/release/overalls" "$out/bin/linux-arm64"
    cp "$CARGO_TARGET_DIR/x86_64-apple-darwin/release/overalls" "$out/bin/darwin-amd64"
    cp "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/overalls" "$out/bin/darwin-arm64"
    # Windows workstations (x86_64; Windows on Arm runs it under emulation).
    # Published without .exe; the installer saves it as overalls.exe.
    cp "$CARGO_TARGET_DIR/x86_64-pc-windows-gnu/release/overalls.exe" "$out/bin/windows-amd64"
    for target in x86_64-unknown-freebsd x86_64-unknown-illumos; do
      for binary in ${lib.concatStringsSep " " nativeBinaries}; do
        install -D -m 0755 "$CARGO_TARGET_DIR/$target/release/$binary" "$out/bin/$target-$binary"
      done
    done
    for binary in "$out"/bin/*; do
      test "$(stat -c %s "$binary")" -le 104857600
    done
    ${pkgs.python3}/bin/python3 - "$out" <<'PY'
import hashlib
import json
import pathlib
import sys

root: pathlib.Path = pathlib.Path(sys.argv[1])
names: tuple[str, ...] = ("linux-amd64", "linux-arm64", "darwin-amd64", "darwin-arm64", "windows-amd64")
artifacts: dict[str, dict[str, str | int]] = {
    name: {
        "path": "/bin/" + name,
        "sha256": hashlib.sha256((root / "bin" / name).read_bytes()).hexdigest(),
        "bytes": (root / "bin" / name).stat().st_size,
    }
    for name in names
}
(root / "manifest.json").write_text(json.dumps({"version": "0.1.0", "artifacts": artifacts}, sort_keys=True))
PY
    runHook postInstall
  '';
  meta = {
    description = "Lyra SSH developer client for Linux, macOS and Windows";
    platforms = [ "x86_64-linux" ];
  };
  passthru.tests = tests;
  passthru.windows = windows;
  passthru.toolchain = toolchain;
  passthru.nativeBinaries = nativeBinaries;
}

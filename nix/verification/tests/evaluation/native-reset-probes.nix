{ pkgs, packages }:
let
  sdk = packages.nativeKernels.illumosToolchain;
in
# @cc [owner:ghuntley,label:verification;build] native-reset-test-only-build
# The reset oracle MUST compile with warnings denied for both native targets,
# preserve their native interpreters, and remain outside production Lyra and
# guest-agent source inputs. Compilation MUST NOT establish event or DMA safety.
pkgs.runCommand "overalls-test-only-native-reset-probes" {
  nativeBuildInputs = [ pkgs.zig pkgs.binutils ];
} ''
  export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global" ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
  mkdir -p "$out/bin"
  zig cc -target x86_64-freebsd -std=c11 -D_DEFAULT_SOURCE -O2 -pthread \
    -Wall -Wextra -Werror ${../support/native_reset_probe.c} -o "$out/bin/freebsd-reset-probe"
  ${sdk.compiler}/bin/illumos-clang -std=c11 -D__EXTENSIONS__ -D_REENTRANT -O2 \
    -Wall -Wextra -Werror ${../support/native_reset_probe.c} \
    -lpthread -lsocket -o "$out/bin/illumos-reset-probe"
  readelf --program-headers --wide "$out/bin/freebsd-reset-probe" > "$out/freebsd-program-headers"
  readelf --program-headers --wide "$out/bin/illumos-reset-probe" > "$out/illumos-program-headers"
  grep -F '[Requesting program interpreter: /libexec/ld-elf.so.1]' "$out/freebsd-program-headers"
  grep -F '[Requesting program interpreter: /usr/lib/amd64/ld.so.1]' "$out/illumos-program-headers"
''

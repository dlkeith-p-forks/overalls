{ pkgs, kernel }:
# @cc [owner:ghuntley,label:build;verification] guest-kernel-load-image-preserved
# Stripping MUST preserve the ELF entry point and every loadable segment's
# address, flags, alignment, memory size and bytes. Debug data remains in a
# separate output; neither guest image may retain the unstripped kernel link.
pkgs.runCommand "lilly-guest-kernel-${kernel.version}" {
  nativeBuildInputs = [ pkgs.binutils pkgs.python3 ];
  outputs = [ "out" "debug" ];
} ''
  mkdir -p "$out" "$debug"
  objcopy --only-keep-debug ${kernel.dev}/vmlinux "$debug/vmlinux.debug"
  objcopy --strip-debug ${kernel.dev}/vmlinux "$out/vmlinux"
  python3 ${./verify-kernel.py} ${kernel.dev}/vmlinux "$out/vmlinux"
''

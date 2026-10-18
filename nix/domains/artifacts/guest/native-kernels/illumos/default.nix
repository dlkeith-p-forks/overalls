{ pkgs, source, sourceRevision, sourceHash, abiPatch, toolchain }:
let
  inherit (pkgs) lib;
  llvm = pkgs.llvmPackages;
  compiler = "clang-${lib.getVersion llvm.clang-unwrapped} (x86_64-pc-solaris2.11)";
  configurationFileHash = builtins.hashFile "sha256" ./amd64-overalls.conf;
  buildRecipeHash = builtins.hashFile "sha256" ./default.nix;
  configurationHash = builtins.hashString "sha256" (builtins.toJSON {
    configuration_file_sha256 = configurationFileHash;
    build_recipe_sha256 = buildRecipeHash;
  });
  patchInputs = {
    abi = builtins.hashFile "sha256" abiPatch;
    modern_virtio = builtins.hashFile "sha256" ./0002-modern-virtio.patch;
    listener_reset = builtins.hashFile "sha256" ./0003-listener-reset.patch;
    block_direct_budget = builtins.hashFile "sha256" ./0004-block-direct-budget.patch;
    driver = builtins.hashFile "sha256" ./viosock.c;
    socket_module = builtins.hashFile "sha256" ./sockvsock.c;
    driver_header = builtins.hashFile "sha256" ./viosock.h;
    public_header = builtins.hashFile "sha256" ./include/sys/vsock.h;
    wire_header = builtins.hashFile "sha256" ../common/ov_vsock.h;
    wire_core = builtins.hashFile "sha256" ../common/ov_vsock.c;
  };
  patchHash = builtins.hashString "sha256" (builtins.toJSON patchInputs);
  buildId = builtins.hashString "sha256" (builtins.toJSON {
    inherit sourceRevision sourceHash patchHash configurationHash compiler;
  });
  frameworkObjects = [
    "io/virtio/virtio_main" "io/virtio/virtio_legacy"
    "io/virtio/virtio_modern" "io/virtio/virtio_dma"
    "io/vioblk/vioblk" "io/vioif/vioif" "io/vioscsi/vioscsi"
    "io/vio9p/vio9p" "crypto/io/viorand"
    "fs/sockfs/socksubr" "fs/sockfs/sockvfsops" "fs/sockfs/sockparams"
    "fs/sockfs/socksyscalls" "fs/sockfs/socktpi" "fs/sockfs/sockstr"
    "fs/sockfs/sockcommon_vnops" "fs/sockfs/sockcommon_subr"
    "fs/sockfs/sockcommon_sops" "fs/sockfs/sockcommon"
    "fs/sockfs/sock_notsupp" "fs/sockfs/socknotify"
    "fs/sockfs/sodirect" "fs/sockfs/sockfilter"
  ];
  unavailableDigest = builtins.hashString "sha256" "native-kernel-artifact-unavailable";
in
# @cc [owner:ghuntley,label:build;verification] illumos-candidate-objects
# Compile the transport, socket module, shared core and all patched framework
# consumers against the complete pinned OS source and official fixed-output
# sysroot. Receipts MUST record actual object hashes and exact patch inputs.
# Relocatable objects MUST NOT be represented as linked/loadable modules or a
# bootable kernel, and MUST NOT open native image admission.
pkgs.runCommand "overalls-illumos-kernel-candidate-objects-${sourceRevision}" {
  nativeBuildInputs = [ llvm.clang-unwrapped llvm.llvm pkgs.patch pkgs.jq pkgs.python313 pkgs.stdenv.cc ];
  passthru = {
    inherit source sourceRevision sourceHash compiler patchHash configurationHash
      configurationFileHash buildRecipeHash patchInputs buildId;
    configuration = ./amd64-overalls.conf;
    artifact = { available = false; bytes = 0; sha256 = unavailableDigest; };
    nativeAdmission = false;
    runtimeValidated = false;
    linked = false;
    nativeHelper = ./native_candidate.py;
  };
} ''
  set -euo pipefail
  cp ${./native_candidate.py} "$TMPDIR/native_candidate.py"
  cp ${./test_native_candidate.py} "$TMPDIR/test_native_candidate.py"
  python3.13 "$TMPDIR/test_native_candidate.py"
  cp -a --reflink=auto ${source} "$TMPDIR/illumos-src"
  chmod -R u+w "$TMPDIR/illumos-src"
  cd "$TMPDIR/illumos-src"
  mkdir -p usr/src/uts/common/io/vsock
  sed -n '/^--- \/dev\/null$/,$p' ${abiPatch} | patch -p1 --forward --batch
  patch -p1 --forward --batch < ${./0002-modern-virtio.patch}
  patch -p1 --forward --batch < ${./0003-listener-reset.patch}
  patch -p1 --forward --batch < ${./0004-block-direct-budget.patch}
  python3.13 ${./extract_listener_reset.py} "$TMPDIR/illumos-src" "$TMPDIR/listener-test"
  $CC -std=c11 -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined \
    -fno-omit-frame-pointer -pthread -I"$TMPDIR/listener-test" \
    ${./listener_reset_test.c} -o "$TMPDIR/listener-reset-test"
  "$TMPDIR/listener-reset-test"
  $CC -std=c11 -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined \
    -fno-omit-frame-pointer -I"$TMPDIR/listener-test" \
    ${./block_budget_test.c} -o "$TMPDIR/block-budget-test"
  "$TMPDIR/block-budget-test"
  $CC -std=c11 -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined \
    -fno-omit-frame-pointer -I"$TMPDIR/listener-test" \
    ${./block_completion_test.c} -o "$TMPDIR/block-completion-test"
  "$TMPDIR/block-completion-test"
  python3.13 ${./extract_viosock_lifetime.py} ${./viosock.c} ${./sockvsock.c} "$TMPDIR/lifetime-test"
  $CC -std=c11 -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined \
    -fno-omit-frame-pointer -I"$TMPDIR/lifetime-test" -I${../common} \
    ${./viosock_lifetime_test.c} -o "$TMPDIR/viosock-lifetime-test"
  "$TMPDIR/viosock-lifetime-test"
  $CC -std=c11 -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined \
    -fno-omit-frame-pointer -pthread -I"$TMPDIR/lifetime-test" -I${../common} \
    ${./socket_handshake_test.c} ${../common/ov_vsock.c} -o "$TMPDIR/socket-handshake-test"
  "$TMPDIR/socket-handshake-test"
  mkdir -p "$out/objects" "$out/include/sys" "$out/share/overalls/native-kernel" "$out/bin"
  install -m 0555 ${./native_candidate.py} "$out/bin/overalls-illumos-candidate"
  evidence="$out/share/overalls/native-kernel"
  uts="$TMPDIR/illumos-src/usr/src/uts"
  declare -a flags=(
    --target=x86_64-pc-solaris2.11 --sysroot=${toolchain.sysroot}
    -D_KERNEL -D_SYSCALL32 -D_SYSCALL32_IMPL -D_ELF64 -D_DDI_STRICT
    -U_XOPEN_SOURCE
    '-DOV_VSOCK_BUILD_ID="${buildId}"'
    -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -fno-common
    -mcmodel=kernel -mno-red-zone -mno-mmx -mno-sse -O2
    -Wno-unknown-pragmas -Wno-missing-field-initializers
    -I${./include} -I${./.} -I${../common}
    -I"$uts/common/io/virtio" -I"$uts/common" -I"$uts/intel" -I"$uts/i86pc"
  )
  declare -a strict=(-Wall -Wextra -Werror -Wno-unknown-pragmas -Wno-missing-field-initializers)
  ${llvm.clang-unwrapped}/bin/clang "''${flags[@]}" "''${strict[@]}" \
    -c ${./viosock.c} -o "$out/objects/viosock.o"
  ${llvm.clang-unwrapped}/bin/clang "''${flags[@]}" "''${strict[@]}" \
    -c ${./sockvsock.c} -o "$out/objects/sockvsock.o"
  ${llvm.clang-unwrapped}/bin/clang "''${flags[@]}" "''${strict[@]}" \
    -c ${../common/ov_vsock.c} -o "$out/objects/ov_vsock.o"
  # Pinned legacy OS code has pre-existing diagnostics. Compile every affected
  # consumer with the same target/kernel flags, without promoting those stock
  # diagnostics to errors; our new transport/core still uses strict warnings.
  for object in ${lib.escapeShellArgs frameworkObjects}; do
    ${llvm.clang-unwrapped}/bin/clang "''${flags[@]}" \
      -I"$(dirname "$uts/common/$object")" -I"$uts/common/fs/sockfs" \
      -c "$uts/common/$object.c" -o "$out/objects/$(basename "$object").o"
  done
  # Clang's Solaris target predefines _XOPEN_SOURCE=600, which would rename
  # sockfs syscall entry points to userland __xnet_* symbols and fail native
  # module loading. Verify the actual object exports, not just preprocessing.
  ${llvm.llvm}/bin/llvm-nm --defined-only --format=posix "$out/objects/socksyscalls.o" \
    > "$evidence/sockfs-syscall-symbols.txt"
  for symbol in bind connect getsockopt recvmsg sendmsg sendto; do
    grep -Eq "^$symbol T " "$evidence/sockfs-syscall-symbols.txt"
  done
  if grep -Eq '^__xnet_' "$evidence/sockfs-syscall-symbols.txt"; then
    echo 'kernel syscall entry points were renamed to userland symbols' >&2
    exit 1
  fi
  cat > "$TMPDIR/public-vsock-abi.c" <<'C'
  #include <sys/vsock.h>
  _Static_assert(AF_VSOCK == 40, "vendor family");
  _Static_assert(VMADDR_CID_HOST == 2, "host CID");
  _Static_assert(VMADDR_CID_ANY == 0xffffffffU, "wildcard CID");
  _Static_assert(VSOCK_SO_BUILD_ID == 1, "build identity option");
  _Static_assert(VSOCK_BUILD_ID_SIZE == 65, "build identity size");
  _Static_assert(sizeof(struct sockaddr_vm) == 16, "address size");
  _Static_assert(__builtin_offsetof(struct sockaddr_vm, svm_family) == 0, "family");
  _Static_assert(__builtin_offsetof(struct sockaddr_vm, svm_port) == 4, "port");
  _Static_assert(__builtin_offsetof(struct sockaddr_vm, svm_cid) == 8, "CID");
  C
  ${llvm.clang-unwrapped}/bin/clang "''${flags[@]}" "''${strict[@]}" \
    -std=c11 -fsyntax-only "$TMPDIR/public-vsock-abi.c"
  cp ${./include/sys/vsock.h} "$out/include/sys/vsock.h"
  : > "$TMPDIR/objects.jsonl"
  for object in "$out"/objects/*.o; do
    ${llvm.llvm}/bin/llvm-readelf --file-header "$object" > "$evidence/$(basename "$object").elf-header"
    grep -Fq 'ELF64' "$evidence/$(basename "$object").elf-header"
    grep -Eq 'Type: +REL ' "$evidence/$(basename "$object").elf-header"
    grep -Fq 'Advanced Micro Devices X86-64' "$evidence/$(basename "$object").elf-header"
    bytes=$(stat -c %s "$object")
    test "$bytes" -gt 0
    digest=$(sha256sum "$object" | cut -d ' ' -f1)
    jq -n --arg name "$(basename "$object")" --argjson bytes "$bytes" --arg sha256 "$digest" \
      '{name:$name,bytes:$bytes,sha256:$sha256}' >> "$TMPDIR/objects.jsonl"
  done
  jq -s . "$TMPDIR/objects.jsonl" > "$evidence/objects.json"
  test "$(jq length "$evidence/objects.json")" -eq 26
  jq -n --slurpfile objects "$evidence/objects.json" \
    --arg source_revision '${sourceRevision}' --arg source_hash '${sourceHash}' \
    --arg patch_hash '${patchHash}' --arg configuration_hash '${configurationHash}' \
    --arg configuration_file_hash '${configurationFileHash}' --arg build_recipe_hash '${buildRecipeHash}' \
    --arg compiler '${compiler}' --argjson patch_inputs '${builtins.toJSON patchInputs}' \
    --arg build_id '${buildId}' \
    --arg unavailable_digest '${unavailableDigest}' \
    '{version:1,os:"illumos",source_revision:$source_revision,source_hash:$source_hash,
      patch_hash:$patch_hash,configuration_hash:$configuration_hash,compiler:$compiler,
      configuration_file_hash:$configuration_file_hash,build_recipe_hash:$build_recipe_hash,
      patch_inputs:$patch_inputs,build_id:$build_id,objects:$objects[0],compiled:true,public_abi_checked:true,
      listener_reset_host_test:true,block_direct_budget_host_test:true,lifetime_fault_injection_host_test:true,
      block_completion_reentrancy_host_test:true,
      kernel_syscall_symbols_checked:true,linked:false,loadable_modules:false,
      runtime_validated:false,native_admission:false,
      artifact:{available:false,bytes:0,sha256:$unavailable_digest}}' > "$evidence/build-receipt.json"
  cp ${./amd64-overalls.conf} "$evidence/kernel.conf"
  printf '%s\n' '${buildId}' > "$evidence/build-id"
''

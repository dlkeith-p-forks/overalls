# OmniOS r151050 userland linker SDK

[`sdk.nix`](../native-kernels/illumos/sdk.nix) assembles an AMD64 userland
sysroot from seven exact package manifests in the official
[`r151050/core` IPS repository](https://pkg.omnios.org/r151050/core/).
Each manifest is pinned by SHA-256. The downloader verifies compressed and
plain SHA-512/256, byte counts and the IPS SHA-1 object key before creating a
file; the complete sysroot additionally has a fixed recursive NAR SHA-256.
Paths and links must remain inside the output, absolute guest links become
relative links, and conflicting or existing output files are refused.

The selected payload contains headers, AMD64 libraries, GCC 13 startup objects
and archives, and all package licenses. It excludes debug variants, compilers
and unrelated executable programs. Original manifests, package identities and
per-file SHA-256/byte records are retained in
`share/overalls/illumos-sdk/provenance.json`; licenses are under `share/licenses`.
The package set includes the exact `system/library` version reported by the
pinned stock OmniOS image, `0.5.11-151050.0:20240426T120154Z`.

The official payload endpoint's TLS certificate chain could not be validated
with the pinned builder CA bundle. Only this credential-free, fixed-output
download disables certificate verification. Exact hash-pinned manifests and
both payload hashes authenticate every extracted byte, followed by the NAR
hash. This limits transport authentication and availability; it changes no
runtime TLS setting. Ordinary SDK compilation and Lyra builds run offline.

The cross compiler is pinned Clang 21.1.8 plus one narrow Solaris-driver patch:
honor an explicit, validated `--ld-path` while retaining GNU linker conventions
selected by `-fuse-ld=bfd`. GNU binutils 2.46 is built for
`x86_64-pc-solaris2.11`, including its Solaris ELF emulations. The wrapper maps
Rust's native Solaris `-z ignore`/`-z record` pair to GNU
`--as-needed`/`--no-as-needed`, retains all other arguments, and adds a
non-executable stack. Guest interpreter paths remain `/usr/lib/amd64/ld.so.1`;
the sysroot is used for link-time library resolution without a runtime RPATH.

`lyra.native` builds all nine native/helper binaries for both FreeBSD and
illumos, records every output's exact digest, size, ELF target, interpreter
and shared libraries, and refuses Linux interpreters/dependencies or runtime
search paths. Its manifest also records the Cargo lockfile hash, pinned tool
versions, Clang patch hash and sysroot NAR hash. The native package is separate
from desktop Lyra downloads and contains eighteen executables. The bounded
transport test probe is built into the separate `lyra.native.probes` output;
it never enters the production agent payload. Native target Clippy uses the
checksum-pinned official component from the same Rust 1.97.1 distribution as
the native standard libraries, because the Nixpkgs compiler's metadata differs
despite the identical release version.

`lyra.native.tests` verifies bounded extraction, hash tampering and link-escape
refusal, compiles and links a real C program, checks its guest interpreter,
and confirms Clang refuses a nonexistent explicit linker. These checks establish
userland linkage, not native kernel-module linkage, custom-vsock availability,
running-kernel attestation or guest-image admission. Both native catalog rows
remain closed under ADR-0190 until their complete runtime evidence exists.

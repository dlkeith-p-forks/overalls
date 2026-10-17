# Native guest kernel inputs

This directory pins FreeBSD 14.3, illumos and OmniOS build source revisions,
reviewed patch files and kernel configuration hashes for native provenance.

The proposed FreeBSD ABI uses vendor family 45 (`AF_VENDOR03`), because family
40 already means `AF_INET_SDP`. Its 16-byte address begins with an 8-bit length
and 8-bit family. The proposed illumos ABI uses the currently unused family 40
and a 16-bit family without a length byte. Both place port32 at offset 4 and
CID32 at offset 8, followed by four zero bytes. These are custom ABI proposals;
neither family is registered by the patch. Rust adapters must match each OS.

The current patches add ABI contract headers only. They do not implement socket
family registration, a virtio transport, stream sockets, queue handling or reset
behavior. The derivations apply those headers to the pinned source and emit build
receipts. Clang checks each proposed address layout against the pinned OS
headers, including family width, size and field offsets. They do not compile a
kernel or SDK.

Every receipt marks its artifact unavailable with zero bytes. The image builders
and fleet catalog refuse native admission. Replacing that receipt requires real
kernel and SDK builds, target-native image assembly, and recorded boot, CID,
malformed-input, reset, isolation and recovery tests. No native runtime support
follows from a passing receipt build or Nix evaluation.

ADR-0188 governs the native kernel and admission requirements.

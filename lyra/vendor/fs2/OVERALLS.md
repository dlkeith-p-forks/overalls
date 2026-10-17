# fs2 0.4.3 illumos patch

Source: crates.io `fs2` version 0.4.3, retained under its upstream MIT/Apache-2.0
licenses. Registry archive SHA-256:
`9564fc758e15025b46aa6643b1b77d047d1a56a1aea6e01002ac0c7026876213`.

The only implementation change adds `target_os = "illumos"` beside `solaris` in
`src/unix.rs`'s allocation fallback. Upstream 0.4.3 has no allocation function
compiled for illumos, preventing every consumer from type-checking. The fallback
preserves the file length unless it needs to grow. Locking implementation and
semantics are unchanged. Native guest runtime acceptance remains separate from
cross-target compilation.

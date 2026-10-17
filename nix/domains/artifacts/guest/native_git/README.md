# Pinned native Git runtimes

`../native-git.nix` exports `freebsd` and `illumos` FHS trees for offline image
assembly, plus `tests` for archive, IPS and ELF search-path refusal checks.

| Family | Executable | HTTPS helper | Trust bundle |
| --- | --- | --- | --- |
| FreeBSD 14.3 | `/usr/local/bin/git` | `/usr/local/libexec/git-core/git-remote-https` | `/etc/ssl/cert.pem` |
| OmniOS r151050 | `/usr/bin/git` | `/usr/libexec/amd64/git-core/git-remote-https` | `/etc/ssl/cacert.pem` |

The FreeBSD lock includes Git-lite 2.49.0 and the complete package dependency
graph from the retained official `FreeBSD:14:amd64/release_3` repository. Archive
SHA-256 values and build-release bounds are checked before extraction. The
packages were built for FreeBSD 14.2 and do not require a newer guest than the
pinned 14.3 base. The CA package's `.sample` link is activated declaratively;
package scripts never execute. The guest must retain the base libraries recorded
in `share/overalls/native-git/elf-dependencies.json` and register `/usr/local/lib`
with `ldconfig` before starting workspace services.

The same lock includes Bash 5.2.37, readline 8.2.13_2 and sudo 1.9.16p2_1 for
native account reconciliation. Only this sudo archive's root-owned
`/usr/local/bin/sudo` mode 04755 is accepted; extraction strips it to 0755 and
records the required guest activation in `activation.json`. Image assembly must
install this file as root:wheel mode 4755 and install the reviewed sudoers policy.
All other set-ID package entries refuse. Package installation scripts never run.

The OmniOS lock pins exact official r151050 IPS manifests, including Git 2.44.3.
Every downloaded object must match its SHA-1 object identity, SHA-512/256 plain
and compressed digests, and size bounds. The entire final runtime tree also has a
pinned recursive Nix hash. Extraction includes Git builtins, native HTTPS
helpers, templates, trust, and their native 64-bit ELF closure. Optional Perl and
shell frontends are excluded. Files/DNS lookup modules, OpenSSL providers and
character-set conversion modules are included as dynamically loaded roots. The
normal `/usr/lib/amd64/ld.so.1` loader alias is installed declaratively.

ELF verification follows each file's declared runpaths, `$ORIGIN`, and reviewed
native default paths; a matching basename elsewhere in the tree is insufficient.
OmniOS unrelated ELF files and their dangling aliases are removed. Source
manifests, downloaded-payload digests and generated aliases remain in
`share/overalls/native-git`; those source records may describe downloaded files
that were later pruned. Linux interpreters, Nix runtime paths, escaping links,
missing interpreters and unresolved dependencies refuse the build.

These checks establish pinned extraction and a static dependency boundary.
Metadata deliberately records `runtime_verified: false`. Native execution,
loader resolution, DNS, TLS trust and an actual HTTPS clone still require guest
machine evidence. The payload does not grant native catalog admission.

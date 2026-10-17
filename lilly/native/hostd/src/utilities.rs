//! The closed set of host utilities hostd may execute.
//!
//! Lilly names a utility by its index in this table; hostd resolves each
//! executable from its own `PATH` once, at startup. A caller can therefore
//! never choose an executable path.

use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

macro_rules! utilities {
    ($($variant:ident = $index:literal, $name:literal, $mutating:literal;)*) => {
        /// One utility in the closed table.
        #[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
        pub enum Utility { $($variant),* }

        impl Utility {
            /// Every utility, in index order.
            pub const ALL: &'static [Utility] = &[$(Utility::$variant),*];

            /// The wire index of this utility.
            pub const fn index(self) -> u8 {
                match self { $(Utility::$variant => $index),* }
            }

            /// The utility for a wire index, if any.
            pub const fn from_index(index: u8) -> Option<Utility> {
                match index { $($index => Some(Utility::$variant),)* _ => None }
            }

            /// The executable name resolved in hostd's `PATH`.
            pub const fn executable(self) -> &'static str {
                match self { $(Utility::$variant => $name),* }
            }

            /// Whether the utility mutates host state and so requires a lease.
            pub const fn mutating(self) -> bool {
                match self { $(Utility::$variant => $mutating),* }
            }
        }
    };
}

// @cc [owner:ghuntley,label:security;protocol] hostd-utility-table-closed
// The table MUST stay index-for-index identical to Lilly.Host.Hostd's
// utility list. Exactly the utilities in Lilly's mutations-require-lock-owner
// set (image copy, file moves and removal, dataset mutations, mounts,
// ownership, keys, FIFOs and transient units) MUST be marked mutating, so
// hostd refuses them without a lease even when the caller's own check is
// bypassed. Network utilities run under Lilly's network lease and are not
// refused here.
utilities! {
    ImageCopy = 0, "lilly-image-copy", true;
    Mkfifo = 1, "mkfifo", true;
    SshKeygen = 2, "ssh-keygen", true;
    KvmProbe = 3, "lilly-kvm-probe", false;
    ResumeToken = 4, "lilly-resume-token", false;
    FlowLabel = 5, "lilly-flow-label", false;
    ZfsNamespaceUnmount = 6, "lilly-zfs-namespace-unmount", true;
    Zfs = 7, "zfs", false;
    ZfsMutation = 8, "zfs", true;
    Truncate = 9, "truncate", true;
    Zpool = 10, "zpool", false;
    Mv = 11, "mv", true;
    Rm = 12, "rm", true;
    Stat = 13, "stat", false;
    Findmnt = 14, "findmnt", false;
    Realpath = 15, "realpath", false;
    Sync = 16, "sync", false;
    Ip = 17, "ip", false;
    Nft = 18, "nft", false;
    Sysctl = 19, "sysctl", false;
    Cp = 20, "cp", true;
    Mount = 21, "mount", true;
    Umount = 22, "umount", true;
    Chown = 23, "chown", true;
    SystemdRun = 24, "systemd-run", true;
    Systemctl = 25, "systemctl", false;
    ImageIdentity = 26, "lilly-image-copy", false;
}

/// Executables resolved once at startup. A utility missing from `PATH`
/// stays unresolved and every request for it reports a setup failure.
#[derive(Debug, Default)]
pub struct Table {
    resolved: Vec<Option<PathBuf>>,
}

impl Table {
    /// Resolve every utility against a `PATH` value.
    pub fn resolve(path: &OsStr) -> Table {
        let directories: Vec<PathBuf> = path
            .as_bytes()
            .split(|byte| *byte == b':')
            .filter(|part| part.starts_with(b"/"))
            .map(|part| PathBuf::from(OsStr::from_bytes(part)))
            .collect();
        let resolved = Utility::ALL
            .iter()
            .map(|utility| {
                directories
                    .iter()
                    .map(|directory| directory.join(utility.executable()))
                    .find(|candidate| executable(candidate))
            })
            .collect();
        Table { resolved }
    }

    /// The resolved absolute executable of a utility.
    pub fn get(&self, utility: Utility) -> Option<&Path> {
        self.resolved
            .get(usize::from(utility.index()))
            .and_then(|path| path.as_deref())
    }
}

fn executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

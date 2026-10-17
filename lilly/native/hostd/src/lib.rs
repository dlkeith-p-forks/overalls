#![deny(unsafe_code)]
#![doc = "lilly-hostd: the host-effects engine. Holds every Lilly lease and runs every host utility."]

pub mod descriptors;
pub mod exec;
pub mod files;
pub mod leases;
pub mod mounts;
pub mod nft_policy;
pub mod policy;
pub mod protocol;
pub mod session;
pub mod transfer;
pub mod utilities;
pub mod vm_launch;
pub mod zfs_policy;

use std::ffi::OsString;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;

/// Parsed command line.
#[derive(Debug, Eq, PartialEq)]
pub struct Options {
    pub socket: PathBuf,
    pub roots: Vec<PathBuf>,
    /// `Some(None)` means "the cgroup hostd was started in".
    pub cgroup: Option<Option<PathBuf>>,
    pub peer_uid: Option<u32>,
    /// The uid Lilly's state belongs to; the peer uid when absent.
    pub service_uid: Option<u32>,
    pub peer_cgroups: Vec<Vec<u8>>,
    /// Exit when stdin reaches EOF (test harnesses that own the daemon).
    pub stdin_lifetime: bool,
    /// Roots for Firecracker API and vsock sockets (jails).
    pub socket_roots: Vec<PathBuf>,
    /// Pool datasets ZFS mutations must stay beneath; none disables the grammar
    /// (a private daemon runs with its owner's privilege anyway).
    pub pool_datasets: Vec<Vec<u8>>,
    /// Roots for native file effects; the lease roots when none are given.
    pub file_roots: Vec<PathBuf>,
    /// Executables and the VM state directory for typed VM launches.
    pub vm_tools: Option<vm_launch::Tools>,
}

/// @cc [owner:ghuntley,label:security] hostd-options-absolute
/// parse_options MUST accept only absolute socket, root and cgroup paths,
/// at least one root, numeric peer and service uids, absolute peer cgroup paths and the
/// bare `--stdin-lifetime` flag, and either all five absolute `--vm-*`
/// paths or none of them, and either no `--pool-dataset` or exactly one per
/// `--socket-root` (paired in order), and
/// return None for any unknown, repeated singular or malformed argument.
pub fn parse_options(arguments: &[OsString]) -> Option<Options> {
    let mut socket = None;
    let mut roots = Vec::new();
    let mut cgroup = None;
    let mut peer_uid = None;
    let mut service_uid = None;
    let mut peer_cgroups = Vec::new();
    let mut stdin_lifetime = false;
    let mut socket_roots = Vec::new();
    let mut file_roots = Vec::new();
    let mut pool_datasets = Vec::new();
    let mut vm: [Option<PathBuf>; 5] = Default::default();
    let mut iterator = arguments.iter();
    while let Some(flag) = iterator.next() {
        if flag.as_bytes() == b"--stdin-lifetime" && !stdin_lifetime {
            stdin_lifetime = true;
            continue;
        }
        let value = iterator.next()?;
        let absolute = value.as_bytes().starts_with(b"/");
        match flag.as_bytes() {
            b"--socket" if socket.is_none() && absolute => socket = Some(PathBuf::from(value)),
            b"--root" if absolute => roots.push(PathBuf::from(value)),
            b"--cgroup" if cgroup.is_none() && value.as_bytes() == b"self" => cgroup = Some(None),
            b"--cgroup" if cgroup.is_none() && absolute => {
                cgroup = Some(Some(PathBuf::from(value)))
            }
            b"--peer-uid" if peer_uid.is_none() => {
                peer_uid = Some(std::str::from_utf8(value.as_bytes()).ok()?.parse().ok()?)
            }
            b"--service-uid" if service_uid.is_none() => {
                service_uid = Some(std::str::from_utf8(value.as_bytes()).ok()?.parse().ok()?)
            }
            b"--peer-cgroup" if absolute => peer_cgroups.push(value.as_bytes().to_vec()),
            b"--socket-root" if absolute => socket_roots.push(PathBuf::from(value)),
            b"--file-root" if absolute => file_roots.push(PathBuf::from(value)),
            b"--pool-dataset" if !absolute && !value.is_empty() => {
                pool_datasets.push(value.as_bytes().to_vec())
            }
            flag if absolute && VM_FLAGS.contains(&flag) => {
                let slot = &mut vm[VM_FLAGS.iter().position(|known| *known == flag)?];
                if slot.replace(PathBuf::from(value)).is_some() {
                    return None;
                }
            }
            _ => return None,
        }
    }
    // Each pool dataset pairs, in order, with its pool directory.
    if roots.is_empty() || (!pool_datasets.is_empty() && pool_datasets.len() != socket_roots.len())
    {
        return None;
    }
    let vm_tools = match vm {
        [None, None, None, None, None] => None,
        [Some(boot_log), Some(unshare), Some(launch_guard), Some(jailer), Some(firecracker)] => {
            Some(vm_launch::Tools {
                boot_log,
                unshare,
                launch_guard,
                jailer,
                firecracker,
            })
        }
        _ => return None,
    };
    Some(Options {
        socket: socket?,
        roots,
        cgroup,
        peer_uid,
        service_uid,
        peer_cgroups,
        stdin_lifetime,
        socket_roots,
        file_roots,
        pool_datasets,
        vm_tools,
    })
}

impl Options {
    /// Configured pools: each `--pool-dataset` with the `--socket-root` at
    /// the same position (parse_options requires equal counts).
    pub fn pools(&self) -> Vec<(Vec<u8>, PathBuf)> {
        self.pool_datasets
            .iter()
            .cloned()
            .zip(self.socket_roots.iter().cloned())
            .collect()
    }
}

/// The `--vm-*` flags, in `vm_launch::Tools` field order.
const VM_FLAGS: [&[u8]; 5] = [
    b"--vm-boot-log",
    b"--vm-unshare",
    b"--vm-launch-guard",
    b"--vm-jailer",
    b"--vm-firecracker",
];

/// The cgroup v2 directory of this process.
pub fn own_cgroup() -> Option<PathBuf> {
    let contents = std::fs::read("/proc/self/cgroup").ok()?;
    let path = contents
        .split(|byte| *byte == b'\n')
        .find_map(|line| line.strip_prefix(b"0::"))?;
    let mut directory = PathBuf::from("/sys/fs/cgroup");
    directory.push(std::ffi::OsStr::from_bytes(path.strip_prefix(b"/")?));
    Some(directory)
}

#[cfg(test)]
mod descriptor_tests;
#[cfg(test)]
mod files_tests;
#[cfg(test)]
mod policy_tests;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod transfer_tests;

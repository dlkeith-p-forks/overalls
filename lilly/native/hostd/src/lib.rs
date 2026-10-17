#![deny(unsafe_code)]
#![doc = "lilly-hostd: the host-effects engine. Holds every Lilly lease and runs every host utility."]

pub mod descriptors;
pub mod exec;
pub mod leases;
pub mod protocol;
pub mod session;
pub mod utilities;

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
    pub peer_cgroups: Vec<Vec<u8>>,
    /// Exit when stdin reaches EOF (test harnesses that own the daemon).
    pub stdin_lifetime: bool,
    /// Roots for Firecracker API and vsock sockets (jails).
    pub socket_roots: Vec<PathBuf>,
}

/// @cc [owner:ghuntley,label:security] hostd-options-absolute
/// parse_options MUST accept only absolute socket, root and cgroup paths,
/// at least one root, a numeric peer uid, absolute peer cgroup paths and the
/// bare `--stdin-lifetime` flag, and
/// return None for any unknown, repeated singular or malformed argument.
pub fn parse_options(arguments: &[OsString]) -> Option<Options> {
    let mut socket = None;
    let mut roots = Vec::new();
    let mut cgroup = None;
    let mut peer_uid = None;
    let mut peer_cgroups = Vec::new();
    let mut stdin_lifetime = false;
    let mut socket_roots = Vec::new();
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
            b"--peer-cgroup" if absolute => peer_cgroups.push(value.as_bytes().to_vec()),
            b"--socket-root" if absolute => socket_roots.push(PathBuf::from(value)),
            _ => return None,
        }
    }
    if roots.is_empty() {
        return None;
    }
    Some(Options {
        socket: socket?,
        roots,
        cgroup,
        peer_uid,
        peer_cgroups,
        stdin_lifetime,
        socket_roots,
    })
}

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
mod tests;

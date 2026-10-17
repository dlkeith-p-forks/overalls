//! Opening sockets Lilly may not open itself, and passing them by descriptor
//! (ADR-0182 step 2).

use crate::protocol::Refusal;
use rustix::event::{PollFd, PollFlags};
use rustix::fs::{Mode as FileMode, OFlags};
use rustix::io::Errno;
use rustix::net::{
    connect, socket_with, AddressFamily, SendAncillaryBuffer, SendAncillaryMessage, SendFlags,
    SocketAddrUnix, SocketAddrV4, SocketFlags, SocketType,
};
use rustix::thread::{move_into_link_name_space, LinkNameSpaceType};
use std::io::IoSlice;
use std::mem::MaybeUninit;
use std::net::Ipv4Addr;
use std::os::fd::{AsFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Basenames of the only Unix sockets hostd connects to for Lilly.
const SOCKET_NAMES: &[&str] = &["api.sock", "v.sock"];

/// @cc [owner:ghuntley,label:security] hostd-unix-socket-confined
/// open_unix MUST connect only to a Firecracker `api.sock` or `v.sock` whose
/// absolute path, free of `.`, `..` and empty components, lies beneath one
/// of the configured socket roots and has no symbolic link at any component
/// below that root; every other path is Unavailable. hostd never connects
/// to other root-owned sockets on Lilly's behalf.
pub fn open_unix(path: &Path, roots: &[PathBuf]) -> Result<OwnedFd, Refusal> {
    let bytes = path.as_os_str().as_encoded_bytes();
    if !crate::protocol::valid_directory(bytes) {
        return Err(Refusal::Malformed);
    }
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("");
    let root = roots
        .iter()
        .find(|root| path.starts_with(root))
        .ok_or(Refusal::Unavailable)?;
    if !SOCKET_NAMES.contains(&name) {
        return Err(Refusal::Unavailable);
    }
    let mut current = root.clone();
    for component in path
        .strip_prefix(root)
        .map_err(|_| Refusal::Unavailable)?
        .components()
    {
        current.push(component);
        let stat = rustix::fs::lstat(&current).map_err(|_| Refusal::Unavailable)?;
        if stat.st_mode & libc::S_IFMT == libc::S_IFLNK {
            return Err(Refusal::Unavailable);
        }
    }
    let socket = socket_with(
        AddressFamily::UNIX,
        SocketType::STREAM,
        SocketFlags::CLOEXEC,
        None,
    )
    .map_err(|_| Refusal::Unavailable)?;
    let address = SocketAddrUnix::new(path).map_err(|_| Refusal::Unavailable)?;
    connect(&socket, &address).map_err(|_| Refusal::Unavailable)?;
    Ok(socket)
}

/// A namespace TCP connection request.
pub struct NetnsTcp {
    pub namespace: String,
    pub device: String,
    pub mark: u32,
    pub destination: Ipv4Addr,
    pub port: u16,
    pub source: Option<Ipv4Addr>,
    pub timeout: Duration,
}

/// @cc [owner:ghuntley,label:security;isolation] hostd-netns-connect
/// open_netns_tcp MUST create the socket on a dedicated thread that entered
/// only `/run/netns/<namespace>` (a name of at most 64 letters, digits, `-`
/// or `_`), so no other hostd thread changes namespace. The socket is bound
/// to the named device (at most 15 such characters), carries the given
/// mark, binds the optional source address, and connects within the
/// timeout; any failure returns Unavailable and closes the socket.
pub fn open_netns_tcp(request: NetnsTcp) -> Result<OwnedFd, Refusal> {
    let name_ok = |name: &str, limit: usize| {
        !name.is_empty()
            && name.len() <= limit
            && name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    };
    if !name_ok(&request.namespace, 64) || !name_ok(&request.device, 15) {
        return Err(Refusal::Malformed);
    }
    std::thread::spawn(move || connect_in_namespace(&request))
        .join()
        .unwrap_or(Err(Refusal::Unavailable))
}

fn connect_in_namespace(request: &NetnsTcp) -> Result<OwnedFd, Refusal> {
    let namespace = rustix::fs::open(
        format!("/run/netns/{}", request.namespace),
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW,
        FileMode::empty(),
    )
    .map_err(|_| Refusal::Unavailable)?;
    move_into_link_name_space(namespace.as_fd(), Some(LinkNameSpaceType::Network))
        .map_err(|_| Refusal::Unavailable)?;
    let socket = socket_with(
        AddressFamily::INET,
        SocketType::STREAM,
        SocketFlags::CLOEXEC | SocketFlags::NONBLOCK,
        None,
    )
    .map_err(|_| Refusal::Unavailable)?;
    raw::configure(&socket, &request.device, request.mark).map_err(|_| Refusal::Unavailable)?;
    if let Some(source) = request.source {
        rustix::net::bind(&socket, &SocketAddrV4::new(source, 0))
            .map_err(|_| Refusal::Unavailable)?;
    }
    match connect(
        &socket,
        &SocketAddrV4::new(request.destination, request.port),
    ) {
        Ok(()) => {}
        Err(Errno::INPROGRESS) => {
            let millis = request.timeout.as_millis().clamp(1, 30_000) as i64;
            let timeout = rustix::event::Timespec {
                tv_sec: millis / 1000,
                tv_nsec: (millis % 1000) * 1_000_000,
            };
            let mut fds = [PollFd::from_borrowed_fd(socket.as_fd(), PollFlags::OUT)];
            match rustix::event::poll(&mut fds, Some(&timeout)) {
                Ok(1) => {}
                _ => return Err(Refusal::Unavailable),
            }
            match rustix::net::sockopt::socket_error(&socket) {
                Ok(Ok(())) => {}
                _ => return Err(Refusal::Unavailable),
            }
        }
        Err(_) => return Err(Refusal::Unavailable),
    }
    // Hand Lilly a blocking socket, as gen_tcp's fd option expects.
    let flags = rustix::fs::fcntl_getfl(&socket).map_err(|_| Refusal::Unavailable)?;
    rustix::fs::fcntl_setfl(&socket, flags - OFlags::NONBLOCK).map_err(|_| Refusal::Unavailable)?;
    Ok(socket)
}

/// Send one datagram carrying a descriptor.
pub fn send_with_descriptor(
    socket: &OwnedFd,
    datagram: &[u8],
    descriptor: &OwnedFd,
) -> rustix::io::Result<usize> {
    let mut space = [MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(1))];
    let mut ancillary = SendAncillaryBuffer::new(&mut space);
    let fds = [descriptor.as_fd()];
    ancillary.push(SendAncillaryMessage::ScmRights(&fds));
    rustix::net::sendmsg(
        socket,
        &[IoSlice::new(datagram)],
        &mut ancillary,
        SendFlags::NOSIGNAL,
    )
}

#[allow(unsafe_code)]
mod raw {
    use std::os::fd::{AsRawFd, OwnedFd};

    /// Set SO_BINDTODEVICE and SO_MARK, which rustix does not wrap.
    pub(super) fn configure(socket: &OwnedFd, device: &str, mark: u32) -> std::io::Result<()> {
        let fd = socket.as_raw_fd();
        // SAFETY: fd is a live socket; the option buffers are valid for the
        // lengths passed.
        let device_result = unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_BINDTODEVICE,
                device.as_ptr().cast(),
                device.len() as libc::socklen_t,
            )
        };
        if device_result != 0 {
            return Err(std::io::Error::last_os_error());
        }
        let mark_result = unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_MARK,
                (&mark as *const u32).cast(),
                std::mem::size_of::<u32>() as libc::socklen_t,
            )
        };
        if mark_result != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }
}

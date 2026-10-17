//! Portable AF_VSOCK transport for the firmware guest agents.
//!
//! FreeBSD and illumos do not expose Linux's `sockaddr_vm` through their
//! `libc` crates.  The wire layout is nevertheless the same 16-byte ABI used
//! by Firecracker's virtio-vsock device, so the small adapter lives here and
//! keeps protocol code independent of a host operating system's bindings.

use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{FromRawFd, RawFd};

/// AF_VSOCK is 40 on Linux, FreeBSD and illumos.
pub const AF_VSOCK: libc::c_int = 40;
/// Firecracker's host CID.
pub const HOST_CID: u32 = 2;
/// The CID assigned to a guest by Lilly's launch contract.
pub const GUEST_CID: u32 = 3;
/// Bind a listener on any local CID.
pub const CID_ANY: u32 = u32::MAX;
const SOCKADDR_VM_SIZE: usize = 16;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SockaddrVm {
    family: u16,
    reserved: u16,
    port: u32,
    cid: u32,
    zero: [u8; 4],
}

impl SockaddrVm {
    fn any(port: u32) -> Self {
        Self {
            family: AF_VSOCK as u16,
            reserved: 0,
            port,
            cid: CID_ANY,
            zero: [0; 4],
        }
    }
}

/// A host-only listener.  [`Listener::accept`] closes a connection before
/// returning an error when its family or peer CID is not trusted.
pub struct Listener {
    fd: RawFd,
}

/// A bounded native-vsock connection with the observed peer CID.
pub struct Connection {
    file: File,
    pub peer_cid: u32,
}

impl Read for Connection {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.file.read(bytes)
    }
}

impl Write for Connection {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.file.write(bytes)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

impl Listener {
    /// Bind `port` and retain at most `backlog` pending peers.
    pub fn bind(port: u32, backlog: libc::c_int) -> io::Result<Self> {
        // SAFETY: all arguments are fixed ABI constants; ownership transfers
        // to this listener when socket succeeds.
        let fd = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM, 0) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        set_close_on_exec(fd)?;
        let address = SockaddrVm::any(port);
        // SAFETY: address is a live 16-byte sockaddr_vm for this call.
        let bound = unsafe {
            libc::bind(
                fd,
                (&raw const address).cast(),
                SOCKADDR_VM_SIZE as libc::socklen_t,
            )
        } == 0;
        // SAFETY: fd is valid and owned by this setup path.
        let listening = bound && unsafe { libc::listen(fd, backlog) } == 0;
        if !listening {
            let error = io::Error::last_os_error();
            // SAFETY: fd is closed exactly once on setup failure.
            unsafe { libc::close(fd) };
            return Err(error);
        }
        Ok(Self { fd })
    }

    /// Accept one peer, requiring AF_VSOCK and the host CID before exposing
    /// the stream to a protocol parser.
    pub fn accept(&self) -> io::Result<Connection> {
        let mut peer = SockaddrVm::default();
        let mut length = SOCKADDR_VM_SIZE as libc::socklen_t;
        // SAFETY: peer and length are writable buffers valid for this call.
        let fd = unsafe { libc::accept(self.fd, (&raw mut peer).cast(), &raw mut length) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        set_close_on_exec(fd)?;
        // SAFETY: fd is newly accepted and owned by the returned connection.
        let file = unsafe { File::from_raw_fd(fd) };
        if length < SOCKADDR_VM_SIZE as libc::socklen_t
            || peer.family != AF_VSOCK as u16
            || peer.cid != HOST_CID
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "non-host vsock peer",
            ));
        }
        set_timeouts(fd)?;
        Ok(Connection {
            file,
            peer_cid: peer.cid,
        })
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        // SAFETY: fd is owned by this listener and closed once.
        unsafe { libc::close(self.fd) };
    }
}

fn set_close_on_exec(fd: RawFd) -> io::Result<()> {
    // SAFETY: fcntl operates on the descriptor just returned by the kernel.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
        let error = io::Error::last_os_error();
        // SAFETY: fd remains owned by this setup path.
        unsafe { libc::close(fd) };
        return Err(error);
    }
    Ok(())
}

fn set_timeouts(fd: RawFd) -> io::Result<()> {
    let timeout = libc::timeval {
        tv_sec: 5,
        tv_usec: 0,
    };
    for option in [libc::SO_RCVTIMEO, libc::SO_SNDTIMEO] {
        // SAFETY: timeout remains live for the synchronous setsockopt call.
        if unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                option,
                (&raw const timeout).cast(),
                std::mem::size_of_val(&timeout) as libc::socklen_t,
            )
        } < 0
        {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn constants_match_guest_launch_contract() {
        assert_eq!(AF_VSOCK, 40);
        assert_eq!(HOST_CID, 2);
        assert_eq!(GUEST_CID, 3);
        assert_eq!(std::mem::size_of::<SockaddrVm>(), SOCKADDR_VM_SIZE);
        assert_eq!(SockaddrVm::any(1024).cid, CID_ANY);
    }
}

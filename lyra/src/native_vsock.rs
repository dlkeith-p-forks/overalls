//! Portable AF_VSOCK transport for the firmware guest agents.
//!
//! Stock FreeBSD and illumos kernels do not implement this transport. This
//! adapter describes ADR-0186's proposed custom kernel socket ABI; compiling
//! it does not establish native kernel or Firecracker transport support.

use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{FromRawFd, RawFd};

/// This custom ABI uses FreeBSD's vendor slot 45 (`AF_VENDOR03`).
#[cfg(target_os = "freebsd")]
pub const AF_VSOCK: libc::c_int = 45;
/// Proposed illumos family; runtime remains unavailable pending kernel evidence.
#[cfg(not(target_os = "freebsd"))]
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
#[cfg(any(target_os = "freebsd", test))]
struct BsdSockaddrVm {
    length: u8,
    family: u8,
    reserved: u16,
    port: u32,
    cid: u32,
    zero: [u8; 4],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
#[cfg(any(not(target_os = "freebsd"), test))]
struct FlatSockaddrVm {
    family: u16,
    reserved: u16,
    port: u32,
    cid: u32,
    zero: [u8; 4],
}

trait VmAddress: Default {
    fn any(port: u32) -> Self;
    fn host_peer(&self) -> bool;
    fn peer_cid(&self) -> u32;
}

#[cfg(any(target_os = "freebsd", test))]
impl VmAddress for BsdSockaddrVm {
    fn any(port: u32) -> Self {
        Self {
            length: SOCKADDR_VM_SIZE as u8,
            family: 45,
            port,
            cid: CID_ANY,
            ..Self::default()
        }
    }
    fn host_peer(&self) -> bool {
        self.length == SOCKADDR_VM_SIZE as u8 && self.family == 45 && self.cid == HOST_CID
    }
    fn peer_cid(&self) -> u32 {
        self.cid
    }
}

#[cfg(any(not(target_os = "freebsd"), test))]
impl VmAddress for FlatSockaddrVm {
    fn any(port: u32) -> Self {
        Self {
            family: 40,
            port,
            cid: CID_ANY,
            ..Self::default()
        }
    }
    fn host_peer(&self) -> bool {
        self.family == 40 && self.cid == HOST_CID
    }
    fn peer_cid(&self) -> u32 {
        self.cid
    }
}

#[cfg(target_os = "freebsd")]
type SockaddrVm = BsdSockaddrVm;
#[cfg(not(target_os = "freebsd"))]
type SockaddrVm = FlatSockaddrVm;

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
    /// @cc [owner:ghuntley,label:security;protocol] native-proposed-vsock-abi
    /// Binding MUST use ADR-0186's reviewed 16-byte custom-kernel ABI with socket
    /// family 45 and BSD length/family bytes on FreeBSD, or the proposed
    /// flat illumos layout. Its use assumes the patched kernel assigns guest
    /// CID 3; successful compilation MUST NOT establish that runtime evidence.
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
        if length != SOCKADDR_VM_SIZE as libc::socklen_t || !peer.host_peer() {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "non-host vsock peer",
            ));
        }
        set_timeouts(fd)?;
        Ok(Connection {
            file,
            peer_cid: peer.peer_cid(),
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
        assert_eq!(AF_VSOCK, if cfg!(target_os = "freebsd") { 45 } else { 40 });
        assert_eq!(HOST_CID, 2);
        assert_eq!(GUEST_CID, 3);
        assert_eq!(std::mem::size_of::<SockaddrVm>(), SOCKADDR_VM_SIZE);
        assert_eq!(SockaddrVm::any(1024).peer_cid(), CID_ANY);
        assert_eq!(std::mem::size_of::<BsdSockaddrVm>(), SOCKADDR_VM_SIZE);
        assert_eq!(std::mem::size_of::<FlatSockaddrVm>(), SOCKADDR_VM_SIZE);
        assert_eq!(std::mem::offset_of!(BsdSockaddrVm, family), 1);
        assert_eq!(std::mem::offset_of!(BsdSockaddrVm, port), 4);
        assert_eq!(std::mem::offset_of!(FlatSockaddrVm, port), 4);
        let mut bsd = BsdSockaddrVm::any(1024);
        assert_eq!(bsd.length, 16);
        assert_eq!(bsd.family, 45);
        assert!(!bsd.host_peer());
        bsd.cid = HOST_CID;
        assert!(bsd.host_peer());
        bsd.length = 0;
        assert!(!bsd.host_peer());
        let mut flat = FlatSockaddrVm::any(1024);
        flat.cid = HOST_CID;
        assert!(flat.host_peer());
        flat.family = 45;
        assert!(!flat.host_peer());
    }
}

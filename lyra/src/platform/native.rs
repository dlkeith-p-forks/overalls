//! POSIX adapters for firmware booted FreeBSD and illumos guests.
//!
//! Both systems receive the Lilly identity from Firecracker MMDS and speak the
//! host-only vsock protocols.  Their libc crates do not expose Linux's VM
//! socket definitions, so this module owns the small ABI-shaped transport and
//! all native filesystem/service probes.

use crate::guest::{mmds, readiness::Boot};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::net::Ipv4Addr;
use std::os::fd::{FromRawFd, RawFd};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Firecracker host CID and VM socket address family.  The values are shared
/// by the FreeBSD virtio-vsock and illumos vmm(4) implementations.
pub const HOST_CID: u32 = 2;
const AF_VSOCK: libc::c_int = 40;
const VMADDR_CID_ANY: u32 = u32::MAX;
const SOCKADDR_VM_SIZE: usize = 16;

#[repr(C)]
#[derive(Clone, Copy)]
struct SockaddrVm {
    family: libc::sa_family_t,
    reserved: u16,
    port: u32,
    cid: u32,
    zero: [u8; 4],
}

/// A native host-only listener. The peer CID is checked before handing a
/// stream to a protocol parser.
pub struct Listener {
    fd: RawFd,
}

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
    /// Bind a VM socket on `port`, accepting at most `backlog` pending peers.
    pub fn bind(port: u32, backlog: libc::c_int) -> io::Result<Self> {
        // SAFETY: all arguments are constants and the returned descriptor is
        // owned by this listener until Drop.
        let fd = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM, 0) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: fcntl operates on the descriptor returned above.
        unsafe {
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        }
        let address = SockaddrVm {
            family: AF_VSOCK as libc::sa_family_t,
            reserved: 0,
            port,
            cid: VMADDR_CID_ANY,
            zero: [0; 4],
        };
        // SAFETY: `address` is the ABI-defined 16-byte sockaddr_vm and lives
        // for the duration of bind.
        let bound = unsafe {
            libc::bind(
                fd,
                (&raw const address).cast(),
                SOCKADDR_VM_SIZE as libc::socklen_t,
            )
        } == 0;
        // SAFETY: fd is valid and owned here.
        let listening = bound && unsafe { libc::listen(fd, backlog) } == 0;
        if !listening {
            let error = io::Error::last_os_error();
            // SAFETY: close the descriptor exactly once on setup failure.
            unsafe { libc::close(fd) };
            return Err(error);
        }
        Ok(Self { fd })
    }

    pub fn accept(&self) -> io::Result<Connection> {
        let mut peer = SockaddrVm {
            family: 0,
            reserved: 0,
            port: 0,
            cid: 0,
            zero: [0; 4],
        };
        let mut length = SOCKADDR_VM_SIZE as libc::socklen_t;
        // SAFETY: peer and length are writable buffers valid for the call.
        let fd = unsafe { libc::accept(self.fd, (&raw mut peer).cast(), &raw mut length) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: fd is a newly accepted descriptor owned by Connection.
        let file = unsafe { File::from_raw_fd(fd) };
        if peer.family != AF_VSOCK as libc::sa_family_t || peer.cid != HOST_CID {
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
        // SAFETY: fd is owned by this listener and is closed once.
        unsafe {
            libc::close(self.fd);
        }
    }
}

fn set_timeouts(fd: RawFd) -> io::Result<()> {
    let timeout = libc::timeval {
        tv_sec: 5,
        tv_usec: 0,
    };
    for option in [libc::SO_RCVTIMEO, libc::SO_SNDTIMEO] {
        // SAFETY: timeout is a valid timeval for the duration of setsockopt.
        let result = unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                option,
                (&raw const timeout).cast(),
                std::mem::size_of_val(&timeout) as libc::socklen_t,
            )
        };
        if result != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Read the MMDS document and bind it to a volatile per-boot UUID.
pub fn identity() -> io::Result<(Boot, Ipv4Addr, Ipv4Addr)> {
    let started = Instant::now();
    let document = loop {
        match mmds::fetch(Duration::from_secs(5)) {
            Ok(document) => break document,
            Err(error) if started.elapsed() < Duration::from_secs(600) => {
                let _ = error;
                std::thread::sleep(Duration::from_secs(2));
            }
            Err(error) => return Err(error),
        }
    };
    let address = document
        .ipv4
        .parse()
        .map_err(|_| io::Error::other("invalid guest address"))?;
    let gateway = document
        .gateway
        .parse()
        .map_err(|_| io::Error::other("invalid guest gateway"))?;
    let boot = Boot::new(
        document.placement,
        document.execution_epoch,
        document.boot_challenge,
        boot_id()?,
    )?;
    Ok((boot, address, gateway))
}

/// The file is created under `/var/run`, which is volatile on both supported
/// native images. A caller may override it in tests or a service sandbox.
pub fn boot_id() -> io::Result<String> {
    let path = std::env::var_os("OVERALLS_BOOT_ID")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/run/overalls/boot-id"));
    if let Ok(value) = fs::read_to_string(&path) {
        let value = value.trim().to_owned();
        if valid_uuid(&value) {
            return Ok(value);
        }
        return Err(io::Error::other("invalid native boot id"));
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut bytes = [0u8; 16];
    File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let value = format_uuid(bytes);
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    match options.open(&path) {
        Ok(mut file) => {
            file.write_all(value.as_bytes())?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            Ok(value)
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => boot_id(),
        Err(error) => Err(error),
    }
}

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

fn format_uuid(bytes: [u8; 16]) -> String {
    let hex = hex::encode(bytes);
    format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    )
}

/// Confirm the delivered `/32` and host route are present. The command output
/// is inspected in memory and never emitted to diagnostics.
pub fn network_ready(address: Ipv4Addr, gateway: Ipv4Addr) -> io::Result<bool> {
    let interface = Command::new("ifconfig")
        .arg("-a")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    let route = Command::new("netstat")
        .args(["-rn"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    if !interface.status.success() || !route.status.success() {
        return Ok(false);
    }
    let address = address.to_string();
    let gateway = gateway.to_string();
    Ok(
        String::from_utf8_lossy(&interface.stdout).contains(&address)
            && String::from_utf8_lossy(&route.stdout).contains(&gateway),
    )
}

/// A synced write on the guest root proves the native filesystem is writable.
pub fn writable_root() -> io::Result<()> {
    let directory = std::env::var_os("OVERALLS_RUN_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/run/overalls"));
    fs::create_dir_all(&directory)?;
    let path = directory.join(format!(".readiness-{}", std::process::id()));
    let mut file = File::create(&path)?;
    file.write_all(b"ready\n")?;
    file.sync_all()?;
    drop(file);
    fs::remove_file(path)
}

/// Native trust-store layouts. The bundle is staged in the state directory
/// and linked into the OS's public CA path by the privileged trust service.
pub fn trust_paths(os: &str) -> io::Result<(&'static str, &'static str)> {
    match os {
        "freebsd" => Ok(("/etc/ssl/cert.pem", "/etc/ssl/cert.pem")),
        "illumos" => Ok((
            "/etc/openssl/certs/ca-certificates.crt",
            "/etc/openssl/certs/ca-certificates.crt",
        )),
        _ => Err(io::Error::other("unsupported native trust layout")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_formatter_emits_lowercase_rfc_shape() {
        let value = format_uuid([
            0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x46, 0x17, 0x98, 0x19, 0x1a, 0x1b, 0x1c, 0x1d,
            0x1e, 0x1f,
        ]);
        assert_eq!(value, "10111213-1415-4617-9819-1a1b1c1d1e1f");
        assert!(valid_uuid(&value));
    }

    #[test]
    fn trust_layout_is_closed() {
        assert_eq!(trust_paths("freebsd").unwrap().0, "/etc/ssl/cert.pem");
        assert_eq!(
            trust_paths("illumos").unwrap().0,
            "/etc/openssl/certs/ca-certificates.crt"
        );
        assert!(trust_paths("linux").is_err());
    }
}

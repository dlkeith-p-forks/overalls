//! Isolated machine-test probe; never part of the native service or agent set.

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
mod native {
    use lyra::guest::kernel_probe;
    use lyra::native_vsock::{Connection, Listener, AF_VSOCK};
    use std::io::{self, Read, Write};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

    const PORT: u32 = 1099;
    const MAX_BYTES: usize = 1_048_576;
    const SOCKETS: usize = 128;

    #[repr(C)]
    struct Address {
        header: [u8; 4],
        port: u32,
        cid: u32,
        zero: [u8; 4],
    }

    impl Address {
        fn new(cid: u32) -> Self {
            Self {
                header: if cfg!(target_os = "freebsd") {
                    [16, 45, 0, 0]
                } else {
                    [40, 0, 0, 0]
                },
                port: 1097,
                cid,
                zero: [0; 4],
            }
        }
    }

    fn socket() -> io::Result<OwnedFd> {
        // SAFETY: fixed native socket constants; ownership transfers on success.
        let fd = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM, 0) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: fd was returned by socket and is owned only by this value.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    fn require_errno(result: libc::c_int, expected: libc::c_int) -> io::Result<()> {
        if result != -1 || io::Error::last_os_error().raw_os_error() != Some(expected) {
            return Err(io::Error::other("native ABI refusal check failed"));
        }
        Ok(())
    }

    /// @cc [owner:ghuntley,label:verification;security] native-test-boundary-refusals
    /// The machine probe MUST refuse to start unless the actual kernel rejects
    /// foreign-CID/malformed binds, outgoing connect, short identity buffers,
    /// identity mutation and socket creation by an unprivileged process. These
    /// checks MUST execute before the test listener can return a build token.
    fn boundaries() -> io::Result<()> {
        let fd = socket()?;
        let bad_bind_error = if cfg!(target_os = "freebsd") {
            libc::EINVAL
        } else {
            libc::EADDRNOTAVAIL
        };
        for cid in [0, 2, 4] {
            let address = Address::new(cid);
            // SAFETY: address is the reviewed 16-byte native ABI for this call.
            require_errno(
                unsafe { libc::bind(fd.as_raw_fd(), (&raw const address).cast(), 16) },
                bad_bind_error,
            )?;
        }
        let mut malformed = Address::new(3);
        malformed.zero[0] = 1;
        // SAFETY: malformed remains a live 16-byte address; the kernel validates it.
        require_errno(
            unsafe { libc::bind(fd.as_raw_fd(), (&raw const malformed).cast(), 16) },
            bad_bind_error,
        )?;
        immutable_buffers(&fd)?;
        socket_capacity()?;
        let host = Address::new(2);
        // SAFETY: host is a live 16-byte address with the public native layout.
        require_errno(
            unsafe { libc::connect(fd.as_raw_fd(), (&raw const host).cast(), 16) },
            libc::EOPNOTSUPP,
        )?;
        let mut token = [0_u8; 65];
        let mut short: libc::socklen_t = 64;
        // SAFETY: token and short are writable for the synchronous option call.
        require_errno(
            unsafe {
                libc::getsockopt(
                    fd.as_raw_fd(),
                    AF_VSOCK,
                    1,
                    token.as_mut_ptr().cast(),
                    &raw mut short,
                )
            },
            libc::EMSGSIZE,
        )?;
        // SAFETY: token is a live 65-byte input buffer; the option is read-only.
        require_errno(
            unsafe { libc::setsockopt(fd.as_raw_fd(), AF_VSOCK, 1, token.as_ptr().cast(), 65) },
            libc::EOPNOTSUPP,
        )?;
        // SAFETY: this test process has not created threads; the child uses only
        // native credential/socket syscalls followed by _exit, without Rust I/O.
        let child = unsafe { libc::fork() };
        if child < 0 {
            return Err(io::Error::last_os_error());
        }
        if child == 0 {
            // SAFETY: no supplementary groups are retained; setuid permanently
            // drops root. The child never returns into the parent test process.
            unsafe {
                if libc::setgroups(0, std::ptr::null()) != 0
                    || libc::setgid(65534) != 0
                    || libc::setuid(65534) != 0
                {
                    libc::_exit(2);
                }
                let unprivileged = libc::socket(AF_VSOCK, libc::SOCK_STREAM, 0);
                if unprivileged >= 0 {
                    libc::close(unprivileged);
                    libc::_exit(3);
                }
                #[cfg(target_os = "freebsd")]
                let error = *libc::__error();
                #[cfg(any(target_os = "illumos", target_os = "solaris"))]
                let error = *libc::___errno();
                libc::_exit(if error == libc::EPERM || error == libc::EACCES {
                    0
                } else {
                    4
                });
            }
        }
        let mut status: libc::c_int = 0;
        loop {
            // SAFETY: child is the owned fork result; status is writable.
            if unsafe { libc::waitpid(child, &raw mut status, 0) } == child {
                break;
            }
            if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                return Err(io::Error::last_os_error());
            }
        }
        if !libc::WIFEXITED(status) || libc::WEXITSTATUS(status) != 0 {
            return Err(io::Error::other(
                "unprivileged socket creation was not refused",
            ));
        }
        Ok(())
    }

    /// @cc [owner:ghuntley,label:verification;security] native-test-fixed-buffer-options
    /// The native kernel MUST refuse send/receive buffer and low-water changes.
    /// FreeBSD's actual send/receive capacities MUST remain exactly 64 KiB.
    fn immutable_buffers(fd: &OwnedFd) -> io::Result<()> {
        let requested: libc::c_int = 1_048_576;
        let expected = if cfg!(target_os = "freebsd") {
            libc::EOPNOTSUPP
        } else {
            libc::ENOPROTOOPT
        };
        for option in [
            libc::SO_SNDBUF,
            libc::SO_RCVBUF,
            libc::SO_SNDLOWAT,
            libc::SO_RCVLOWAT,
        ] {
            // SAFETY: requested is a live native integer input, of exact size.
            require_errno(
                unsafe {
                    libc::setsockopt(
                        fd.as_raw_fd(),
                        libc::SOL_SOCKET,
                        option,
                        (&raw const requested).cast(),
                        size_of::<libc::c_int>() as libc::socklen_t,
                    )
                },
                expected,
            )?;
        }
        #[cfg(target_os = "freebsd")]
        for option in [libc::SO_SNDBUF, libc::SO_RCVBUF] {
            let mut actual: libc::c_int = 0;
            let mut length = size_of::<libc::c_int>() as libc::socklen_t;
            // SAFETY: actual and length are writable native integer outputs.
            if unsafe {
                libc::getsockopt(
                    fd.as_raw_fd(),
                    libc::SOL_SOCKET,
                    option,
                    (&raw mut actual).cast(),
                    &raw mut length,
                )
            } != 0
                || actual != 65_536
                || length != size_of::<libc::c_int>() as libc::socklen_t
            {
                return Err(io::Error::other("native socket capacity differs"));
            }
        }
        Ok(())
    }

    /// @cc [owner:ghuntley,label:verification;security] native-test-socket-pool-cap
    /// With only the caller's boundary socket live, exactly 127 further sockets
    /// MUST open and socket 129 MUST refuse with ENOBUFS. Closing the extra
    /// sockets MUST restore that complete capacity for a second pass.
    fn socket_capacity() -> io::Result<()> {
        for _ in 0..2 {
            let mut pool = Vec::with_capacity(SOCKETS - 1);
            for _ in 1..SOCKETS {
                pool.push(socket()?);
            }
            match socket() {
                Err(error) if error.raw_os_error() == Some(libc::ENOBUFS) => {}
                _ => return Err(io::Error::other("native socket pool bound differs")),
            }
            drop(pool);
        }
        Ok(())
    }

    /// @cc [owner:ghuntley,label:verification;security] native-test-probe-framing
    /// The test-only listener MUST verify the running transport build identity
    /// and host CID before exposing its bounded echo protocol. Each exchange
    /// MUST be length-delimited, at most 1 MiB, and contain no diagnostic copy
    /// of payload bytes. This helper MUST NOT grant production readiness.
    fn exchange(connection: &mut Connection, build_id: &str) -> io::Result<()> {
        writeln!(connection, "NATIVE 1 {build_id} 3 2")?;
        let mut header = [0_u8; 4];
        connection.read_exact(&mut header)?;
        let length = u32::from_le_bytes(header) as usize;
        if length > MAX_BYTES {
            return Err(io::Error::other("probe input exceeds bound"));
        }
        let mut remaining = length;
        let mut buffer = [0_u8; 16_384];
        while remaining != 0 {
            let limit = remaining.min(buffer.len());
            let count = connection.read(&mut buffer[..limit])?;
            if count == 0 {
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
            connection.write_all(&buffer[..count])?;
            remaining -= count;
        }
        connection.flush()?;
        // Firecracker 1.16 treats Unix EOF as a full vsock shutdown. An explicit
        // acknowledgement keeps both directions open until the echo is read.
        let mut acknowledgement = [0_u8; 1];
        connection.read_exact(&mut acknowledgement)?;
        if acknowledgement != [0xa5] {
            return Err(io::Error::other("invalid probe acknowledgement"));
        }
        Ok(())
    }

    /// One received frame header in the virtio-vsock little-endian layout.
    #[cfg(target_os = "freebsd")]
    fn frame(source: u64, target: u64, source_port: u32, target_port: u32) -> [u8; 44] {
        let mut bytes = [0_u8; 44];
        bytes[0..8].copy_from_slice(&source.to_le_bytes());
        bytes[8..16].copy_from_slice(&target.to_le_bytes());
        bytes[16..20].copy_from_slice(&source_port.to_le_bytes());
        bytes[20..24].copy_from_slice(&target_port.to_le_bytes());
        bytes[28..30].copy_from_slice(&1_u16.to_le_bytes());
        bytes[30..32].copy_from_slice(&1_u16.to_le_bytes());
        bytes[36..40].copy_from_slice(&65_536_u32.to_le_bytes());
        bytes
    }

    #[cfg(target_os = "freebsd")]
    fn inject(bytes: &[u8]) -> Result<(), libc::c_int> {
        // SAFETY: the OID name is NUL-terminated; bytes is a live input buffer
        // and no output buffer is requested.
        let result = unsafe {
            libc::sysctlbyname(
                c"debug.overalls_vsock_inject".as_ptr(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                bytes.as_ptr().cast(),
                bytes.len(),
            )
        };
        if result == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error().raw_os_error().unwrap_or(0))
        }
    }

    #[cfg(target_os = "freebsd")]
    fn pending(listener: &OwnedFd) -> io::Result<bool> {
        let mut poll = libc::pollfd {
            fd: listener.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: poll is one live descriptor record for this bounded wait.
        let ready = unsafe { libc::poll(&raw mut poll, 1, 200) };
        if ready < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(ready == 1 && poll.revents & libc::POLLIN != 0)
    }

    /// @cc [owner:ghuntley,label:verification;security] native-test-wrong-cid-injection
    /// On the separately identified fault kernel, frames with any source other
    /// than host CID 2, any destination other than guest CID 3, or CIDs with
    /// upper 32-bit bits set MUST be refused by the kernel decoder (EBADMSG)
    /// and MUST NOT make a listener readable. A correctly addressed request
    /// MUST pass the same injection path and make the listener readable, so
    /// the refusals are not an artifact of an unreachable path. These checks
    /// MUST execute before the test listener can return a build token.
    #[cfg(target_os = "freebsd")]
    fn wrong_cid_injection() -> io::Result<()> {
        const PORT_UNDER_TEST: u32 = 1100;
        let fd = socket()?;
        let mut address = Address::new(u32::MAX);
        address.port = PORT_UNDER_TEST;
        // SAFETY: address is the reviewed 16-byte native ABI for this call.
        if unsafe { libc::bind(fd.as_raw_fd(), (&raw const address).cast(), 16) } != 0
            // SAFETY: fd is a bound native stream socket.
            || unsafe { libc::listen(fd.as_raw_fd(), 4) } != 0
        {
            return Err(io::Error::last_os_error());
        }
        let wide = 1_u64 << 32;
        let refused = [
            (4, 3),
            (3, 3),
            (0, 3),
            (1, 3),
            (u64::from(u32::MAX), 3),
            (u64::MAX, 3),
            (2 | wide, 3),
            (2, 2),
            (2, 4),
            (2, 0),
            (2, u64::from(u32::MAX)),
            (2, 3 | wide),
        ];
        for (source, target) in refused {
            if inject(&frame(source, target, 5000, PORT_UNDER_TEST)) != Err(libc::EBADMSG) {
                return Err(io::Error::other("wrong-CID frame was not refused"));
            }
            if pending(&fd)? {
                return Err(io::Error::other("wrong-CID frame reached the listener"));
            }
        }
        let mut truncated = frame(2, 3, 5000, PORT_UNDER_TEST).to_vec();
        truncated[24..28].copy_from_slice(&8_u32.to_le_bytes());
        if inject(&truncated) != Err(libc::EBADMSG) || pending(&fd)? {
            return Err(io::Error::other("length-mismatched frame was not refused"));
        }
        if inject(&frame(2, 3, 5001, PORT_UNDER_TEST)).is_err() || !pending(&fd)? {
            return Err(io::Error::other(
                "injection path did not reach the listener",
            ));
        }
        Ok(())
    }

    pub fn run(require_fault_injection: bool) -> io::Result<()> {
        boundaries()?;
        if require_fault_injection {
            #[cfg(target_os = "freebsd")]
            wrong_cid_injection()?;
            #[cfg(not(target_os = "freebsd"))]
            return Err(io::Error::other("fault injection is FreeBSD-only"));
        }
        let listener = Listener::bind(PORT, 8)?;
        let initial = kernel_probe::verified_build_id(&listener)?;
        loop {
            let mut connection = listener.accept()?;
            if kernel_probe::verified_build_id(&listener)? != initial {
                return Err(io::Error::other("changed transport identity"));
            }
            // Malformed or disconnected histories consume only that stream.
            let _ = exchange(&mut connection, &initial);
        }
    }
}

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    let mut arguments = std::env::args().skip(1);
    let require_fault_injection = match (arguments.next().as_deref(), arguments.next()) {
        (None, None) => false,
        (Some("--require-fault-injection"), None) => true,
        _ => std::process::exit(64),
    };
    std::process::exit(if native::run(require_fault_injection).is_ok() {
        0
    } else {
        1
    });
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64);
}

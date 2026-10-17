//! Readiness daemon for native FreeBSD and illumos guests.

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    use lyra::guest::readiness::{self, Probe};
    use lyra::native_guest;
    use lyra::native_vsock::{self, Listener};
    use std::io::{self, Write};
    use std::net::Ipv4Addr;

    struct Live {
        address: Ipv4Addr,
        gateway: Ipv4Addr,
    }
    impl Probe for Live {
        fn ready(&mut self) -> io::Result<bool> {
            Ok(native_guest::network_ready(self.address, self.gateway)?
                && native_guest::writable_root().is_ok())
        }
    }

    let (boot, address, gateway) = match native_guest::identity() {
        Ok(value) => value,
        Err(_) => std::process::exit(1),
    };
    let listener = match Listener::bind(readiness::PORT, 4) {
        Ok(value) => value,
        Err(_) => std::process::exit(2),
    };
    let mut probe = Live { address, gateway };
    loop {
        let mut connection = match listener.accept() {
            Ok(value) => value,
            Err(_) => continue,
        };
        if let Ok(Some(response)) = readiness::answer(
            connection.peer_cid,
            native_vsock::HOST_CID,
            &boot,
            &mut probe,
        ) {
            let _ = connection.write_all(&response);
        }
    }
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64)
}

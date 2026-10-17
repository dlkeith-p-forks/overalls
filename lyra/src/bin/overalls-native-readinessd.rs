//! Readiness daemon for FreeBSD and illumos firmware guests.
//! It answers only host-CID-2 polls after network, service and durable-root probes.

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
mod daemon {
    use lyra::guest::readiness::{self, Probe};
    use lyra::platform::native::{self, Listener, HOST_CID};
    use std::io;
    use std::net::Ipv4Addr;

    struct Live {
        address: Ipv4Addr,
        gateway: Ipv4Addr,
    }

    impl Probe for Live {
        fn ready(&mut self) -> io::Result<bool> {
            if !native::network_ready(self.address, self.gateway)? {
                return Ok(false);
            }
            native::writable_root()?;
            Ok(true)
        }
    }

    pub fn run() -> i32 {
        let (boot, address, gateway) = match native::identity() {
            Ok(identity) => identity,
            Err(_) => return 1,
        };
        let listener = match Listener::bind(readiness::PORT, 4) {
            Ok(listener) => listener,
            Err(_) => return 2,
        };
        let mut probe = Live { address, gateway };
        loop {
            let mut connection = match listener.accept() {
                Ok(connection) => connection,
                Err(_) => continue,
            };
            if let Ok(Some(response)) =
                readiness::answer(connection.peer_cid, HOST_CID, &boot, &mut probe)
            {
                let _ = std::io::Write::write_all(&mut connection, &response);
            }
        }
    }
}

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    std::process::exit(daemon::run());
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64);
}

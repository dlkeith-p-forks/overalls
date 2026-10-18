//! Readiness daemon for native FreeBSD and illumos guests.

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    use lyra::guest::{
        kernel_probe,
        readiness::{self, Probe},
    };
    use lyra::native_guest;
    use lyra::native_vsock::{self, Listener};
    use std::io::{self, Write};
    use std::net::Ipv4Addr;

    struct Live<'a> {
        address: Ipv4Addr,
        gateway: Ipv4Addr,
        os: &'static str,
        kernel_digest: String,
        kernel_build_id: String,
        listener: &'a Listener,
    }
    impl Probe for Live<'_> {
        fn ready(&mut self) -> io::Result<bool> {
            Ok(native_guest::services_ready()?
                && native_guest::network_ready(self.address, self.gateway)?
                && native_guest::writable_root().is_ok()
                && kernel_probe::verified_build_id(self.listener)
                    .is_ok_and(|current| current == self.kernel_build_id)
                && kernel_probe::kernel_sha256(self.os)
                    .is_ok_and(|current| current == self.kernel_digest))
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
    let os = if cfg!(target_os = "freebsd") {
        "freebsd"
    } else {
        "illumos"
    };
    let kernel_digest = match kernel_probe::kernel_sha256(os) {
        Ok(digest) => digest,
        Err(_) => std::process::exit(3),
    };
    let kernel_build_id = match kernel_probe::verified_build_id(&listener) {
        Ok(build_id) => build_id,
        Err(_) => std::process::exit(4),
    };
    let mut probe = Live {
        address,
        gateway,
        os,
        kernel_digest,
        kernel_build_id,
        listener: &listener,
    };
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

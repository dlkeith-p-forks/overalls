//! Boot-bound trust bundle installer for native guests.

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    use lyra::guest::trust;
    use lyra::native_guest;
    use lyra::native_vsock::Listener;
    use std::path::Path;

    let os = if cfg!(target_os = "freebsd") {
        "freebsd"
    } else {
        "illumos"
    };
    let (boot, _, _) = match native_guest::identity() {
        Ok(value) => value,
        Err(_) => std::process::exit(1),
    };
    let listener = match Listener::bind(trust::PORT, 1) {
        Ok(value) => value,
        Err(_) => std::process::exit(2),
    };
    loop {
        let mut connection = match listener.accept() {
            Ok(value) => value,
            Err(_) => continue,
        };
        let request = match trust::read_frame(&mut connection) {
            Ok(value) => value,
            Err(_) => continue,
        };
        let (base, destination) = match native_guest::trust_paths(os) {
            Ok(value) => value,
            Err(_) => continue,
        };
        if native_guest::install_trust(
            Path::new(base),
            Path::new(destination),
            Path::new("/var/lib/overalls-trust"),
            &request,
            &boot,
        )
        .is_err()
        {
            continue;
        }
        let _ = trust::write_frame(&mut connection, &trust::receipt(&request, &boot));
    }
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64)
}

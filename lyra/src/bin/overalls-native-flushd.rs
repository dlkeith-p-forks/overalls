//! Boot-bound native filesystem flush daemon (vsock port 1026).

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn run() -> std::io::Result<()> {
    use lyra::{guest::flush, native_guest, native_vsock::Listener};
    let (boot, _, _) = native_guest::identity()?;
    let listener = Listener::bind(flush::PORT, 1)?;
    loop {
        let mut connection = match listener.accept() {
            Ok(connection) => connection,
            Err(_) => continue,
        };
        // Malformed input, a rejected peer and a reset affect one connection.
        let _ = flush::answer(&mut connection, &boot, native_guest::flush_root);
    }
}

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    std::process::exit(if run().is_ok() { 0 } else { 1 });
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64);
}

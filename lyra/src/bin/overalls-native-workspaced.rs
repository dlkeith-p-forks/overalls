//! Boot-bound workspace receiver for FreeBSD and illumos guests.

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
mod daemon {
    use lyra::platform::native::Listener;
    use lyra::workspace_receiver::{self as receiver, Binding, Paths, Receiver, Retry, SystemGit};
    use lyra::workspace_source::WorkspaceSource;
    use std::io;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread;

    const GIT: &str = "/usr/bin/git";
    const FREEBSD_CA: &str = "/etc/ssl/cert.pem";
    const ILLUMOS_CA: &str = "/etc/openssl/certs/ca-certificates.crt";

    fn spawn_clone(
        state: &Arc<Receiver>,
        cloning: &Arc<AtomicBool>,
        source: WorkspaceSource,
        ca: PathBuf,
    ) {
        if cloning.swap(true, Ordering::SeqCst) {
            return;
        }
        let state = Arc::clone(state);
        let flag = Arc::clone(cloning);
        thread::spawn(move || {
            let mut git = SystemGit {
                program: PathBuf::from(GIT),
                ca_bundle: ca,
                home: state.paths().state.clone(),
            };
            let _ =
                state.clone_with_retry(&source, &mut git, Retry::GUEST, &mut thread::sleep, || {});
            flag.store(false, Ordering::SeqCst);
        });
    }

    pub fn run(os: &str) -> io::Result<()> {
        let (boot, _, _) = lyra::platform::native::identity()?;
        let binding = Binding {
            placement_id: boot.placement_id,
            execution_epoch: boot.execution_epoch,
            boot_challenge: boot.boot_challenge,
        };
        let state = Arc::new(Receiver::new(Paths::guest())?);
        let cloning = Arc::new(AtomicBool::new(false));
        let ca = PathBuf::from(if os == "freebsd" {
            FREEBSD_CA
        } else {
            ILLUMOS_CA
        });
        if let Some(source) = state.start()? {
            spawn_clone(&state, &cloning, source, ca.clone());
        }
        let listener = Listener::bind(receiver::PORT, 4)?;
        loop {
            let mut connection = listener.accept()?;
            match receiver::answer(&mut connection, &binding, &state) {
                Ok((decision, source)) if decision.clone => {
                    spawn_clone(&state, &cloning, source, ca.clone())
                }
                Ok(_) | Err(_) => {}
            }
        }
    }
}

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    let os = if cfg!(target_os = "freebsd") {
        "freebsd"
    } else {
        "illumos"
    };
    std::process::exit(match daemon::run(os) {
        Ok(()) => 0,
        Err(_) => 1,
    });
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64);
}

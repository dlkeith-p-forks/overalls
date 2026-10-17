//! Boot-bound source-v2 workspace receiver for native guests.

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    use lyra::native_guest;
    use lyra::native_vsock::Listener;
    use lyra::workspace_receiver::{self as receiver, Binding, Paths, Receiver, Retry, SystemGit};
    use lyra::workspace_source::WorkspaceSource;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread;

    let os = if cfg!(target_os = "freebsd") {
        "freebsd"
    } else {
        "illumos"
    };
    let (boot, _, _) = match native_guest::identity() {
        Ok(value) => value,
        Err(_) => std::process::exit(1),
    };
    let binding = Binding {
        placement_id: boot.placement_id,
        execution_epoch: boot.execution_epoch,
        boot_challenge: boot.boot_challenge,
    };
    let state = match Receiver::new(Paths::guest()) {
        Ok(value) => Arc::new(value),
        Err(_) => std::process::exit(2),
    };
    let cloning = Arc::new(AtomicBool::new(false));
    let (git_program, ca) = if os == "freebsd" {
        (
            PathBuf::from("/usr/local/bin/git"),
            PathBuf::from("/etc/ssl/cert.pem"),
        )
    } else {
        (
            PathBuf::from("/usr/bin/git"),
            PathBuf::from("/etc/ssl/cacert.pem"),
        )
    };
    let spawn = |state: &Arc<Receiver>, cloning: &Arc<AtomicBool>, source: WorkspaceSource| {
        if cloning.swap(true, Ordering::SeqCst) {
            return;
        }
        let state = Arc::clone(state);
        let flag = Arc::clone(cloning);
        let git_program = git_program.clone();
        let ca = ca.clone();
        let _ = thread::Builder::new()
            .name("workspace-clone".into())
            .spawn(move || {
                let mut git = SystemGit {
                    program: git_program,
                    ca_bundle: ca,
                    home: state.paths().state.clone(),
                };
                let _ = state.clone_with_retry(
                    &source,
                    &mut git,
                    Retry::GUEST,
                    &mut thread::sleep,
                    || {},
                );
                flag.store(false, Ordering::SeqCst);
            });
    };
    if let Ok(Some(source)) = state.start() {
        spawn(&state, &cloning, source);
    }
    let listener = match Listener::bind(receiver::PORT, 4) {
        Ok(value) => value,
        Err(_) => std::process::exit(3),
    };
    loop {
        let mut connection = match listener.accept() {
            Ok(value) => value,
            Err(_) => continue,
        };
        match receiver::answer(&mut connection, &binding, &state) {
            Ok((decision, source)) if decision.clone => spawn(&state, &cloning, source),
            Ok(_) | Err(_) => {}
        }
    }
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64)
}

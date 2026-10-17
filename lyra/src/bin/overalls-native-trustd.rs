//! Boot-bound trust bundle installer for native guests.

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    use lyra::guest::trust;
    use lyra::native_guest;
    use lyra::native_vsock::Listener;
    use std::fs::{self, File, OpenOptions};
    use std::io::{self, Write};
    use std::os::unix::fs::symlink;
    use std::path::{Path, PathBuf};

    fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
        let parent = path
            .parent()
            .ok_or_else(|| io::Error::other("trust path"))?;
        fs::create_dir_all(parent)?;
        let next = parent.join(".overalls-ca.next");
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&next)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&next, path)?;
        File::open(parent)?.sync_all()
    }

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
        if trust::validate(&request, &boot).is_err() {
            continue;
        }
        let (base, destination) = match native_guest::trust_paths(os) {
            Ok(value) => value,
            Err(_) => continue,
        };
        let bundle = match trust::bundle(&fs::read(base).unwrap_or_default(), &request.roots) {
            Ok(value) => value,
            Err(_) => continue,
        };
        let state = PathBuf::from("/var/lib/overalls-trust");
        if fs::create_dir_all(&state).is_err() {
            continue;
        }
        let staged = state.join(format!("bundle-{}.pem", request.bundle_digest));
        if staged.exists() {
            if !fs::read(&staged)
                .map(|bytes| bytes == bundle)
                .unwrap_or(false)
            {
                continue;
            }
        } else if atomic_write(&staged, &bundle).is_err() {
            continue;
        }
        let destination = Path::new(destination);
        let parent = match destination.parent() {
            Some(value) => value,
            None => continue,
        };
        if fs::create_dir_all(parent).is_err() {
            continue;
        }
        let next = parent.join(".overalls-ca-link.next");
        let _ = fs::remove_file(&next);
        if symlink(&staged, &next).is_err() || fs::rename(next, destination).is_err() {
            continue;
        }
        let _ = trust::write_frame(&mut connection, &trust::receipt(&request, &boot));
    }
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64)
}

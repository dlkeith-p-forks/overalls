//! Boot-bound public CA installer for FreeBSD and illumos guests.

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
mod daemon {
    use lyra::guest::trust;
    use lyra::platform::native::{self, Listener};
    use std::fs::{self, File, OpenOptions};
    use std::io::{self, Write};
    use std::path::{Path, PathBuf};

    const STATE: &str = "/var/lib/overalls-trust";

    fn atomic_bundle(path: &Path, bytes: &[u8]) -> io::Result<()> {
        let parent = path
            .parent()
            .ok_or_else(|| io::Error::other("invalid trust path"))?;
        fs::create_dir_all(parent)?;
        let next = parent.join(".ca-bundle.next");
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

    fn install(os: &str, roots: &[String], digest: &str) -> io::Result<()> {
        let (base, destination) = native::trust_paths(os)?;
        let base = fs::read(base)?;
        let bytes = trust::bundle(&base, roots)?;
        let state = Path::new(STATE);
        fs::create_dir_all(state)?;
        let staged = state.join(format!("bundle-{digest}.pem"));
        if !staged.exists() {
            atomic_bundle(&staged, &bytes)?;
        } else if fs::read(&staged)? != bytes {
            return Err(io::Error::other("trust bundle conflict"));
        }
        let parent = PathBuf::from(destination)
            .parent()
            .map(Path::to_path_buf)
            .ok_or_else(|| io::Error::other("invalid trust destination"))?;
        fs::create_dir_all(&parent)?;
        let next = parent.join(".overalls-ca.next");
        let _ = fs::remove_file(&next);
        std::os::unix::fs::symlink(&staged, &next)?;
        fs::rename(next, destination)?;
        File::open(parent)?.sync_all()
    }

    pub fn run(os: &str) -> i32 {
        let (boot, _, _) = match native::identity() {
            Ok(value) => value,
            Err(_) => return 1,
        };
        let listener = match Listener::bind(trust::PORT, 1) {
            Ok(value) => value,
            Err(_) => return 2,
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
            let roots_pem = request.roots.clone();
            if install(os, &roots_pem, &request.bundle_digest).is_err() {
                continue;
            }
            let receipt = trust::receipt(&request, &boot);
            let _ = trust::write_frame(&mut connection, &receipt);
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
    std::process::exit(daemon::run(os));
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64);
}

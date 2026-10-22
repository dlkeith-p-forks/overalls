//! Bounded regular-file reads and durable replacement for SSH runtime state.
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;

/// @cc [owner:ghuntley,label:security] ssh-files-regular-bounded
/// Reads MUST inspect the opened descriptor, reject symlinks and nonregular
/// files without blocking, and enforce the byte limit even if the file grows.
/// On Windows the open MUST NOT traverse a reparse point in the final
/// component (`FILE_FLAG_OPEN_REPARSE_POINT`), so a symlink is seen as such.
pub fn read(path: &Path, maximum: usize) -> io::Result<Vec<u8>> {
    read_regular(path, maximum, false)
}

/// @cc [owner:ghuntley,label:security] ssh-files-system-public-trust
/// System public trust reads MAY follow configuration symlinks, but MUST reject
/// nonregular descriptors without blocking and enforce the byte limit. Private
/// keys and application-managed state MUST use the non-following reader.
pub fn read_system_public_trust(path: &Path, maximum: usize) -> io::Result<Vec<u8>> {
    read_regular(path, maximum, true)
}

/// Open `path` for reading without following a final-component link and
/// without blocking on a FIFO or device. Callers MUST still inspect the opened
/// descriptor's metadata before trusting it as a regular file.
pub fn open_no_follow(path: &Path) -> io::Result<File> {
    open_regular(path, false)
}

#[cfg(unix)]
fn open_regular(path: &Path, follow: bool) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    let flags = if follow { 0 } else { libc::O_NOFOLLOW };
    OpenOptions::new()
        .read(true)
        .custom_flags(flags | libc::O_NONBLOCK)
        .open(path)
}

#[cfg(windows)]
fn open_regular(path: &Path, follow: bool) -> io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    // FILE_FLAG_OPEN_REPARSE_POINT: open the link itself, never its target.
    const OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    let mut options = OpenOptions::new();
    options.read(true);
    if !follow {
        options.custom_flags(OPEN_REPARSE_POINT);
    }
    options.open(path)
}

fn read_regular(path: &Path, maximum: usize, follow: bool) -> io::Result<Vec<u8>> {
    let file = open_regular(path, follow)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > maximum as u64 {
        return Err(io::Error::other("invalid SSH file"));
    }
    let mut bytes = Vec::new();
    file.take(maximum as u64 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > maximum {
        return Err(io::Error::other("oversized SSH file"));
    }
    Ok(bytes)
}

/// @cc [owner:ghuntley,label:security;recovery] ssh-files-durable-replacement
/// Replacement MUST publish a complete private file atomically and sync both
/// the file and parent directory. Callers MUST control the parent directory:
/// on Unix the file is created mode 0600, on Windows it inherits the parent's
/// ACL, so the parent MUST already be private.
pub fn atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("invalid SSH path"))?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.as_file()
            .set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    file.write_all(bytes)?;
    file.as_file().sync_all()?;
    let staged = file.into_temp_path().keep().map_err(|error| error.error)?;
    crate::durable::rename(&staged, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&staged);
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn refuses_links_directories_and_oversized_files() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("state");
        atomic(&path, b"state").unwrap();
        assert_eq!(read(&path, 5).unwrap(), b"state");
        assert!(read(&path, 4).is_err());
        assert!(read(root.path(), 100).is_err());
        let link = root.path().join("link");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&path, &link).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_file(&path, &link).unwrap();
        assert!(read(&link, 100).is_err());
        assert_eq!(read_system_public_trust(&link, 5).unwrap(), b"state");
        assert!(read_system_public_trust(&link, 4).is_err());
        assert!(read_system_public_trust(root.path(), 100).is_err());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }
}

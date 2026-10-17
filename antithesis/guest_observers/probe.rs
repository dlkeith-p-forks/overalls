//! Fixed synthetic PTY-input witness; no command or payload logging.
use std::fs::{DirBuilder, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::Path;

const DIRECTORY: &str = "/run/overalls-terminal-probe";
const LEDGER: &str = "/run/overalls-terminal-probe/ledger";
const MAX_RECORDS: u64 = 128;
const OFFSET: u128 = 0x6c62272e07bb014262b821756295c58d;
const PRIME: u128 = 0x0000000001000000000000000000013b;

unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}

fn digest(marker: &[u8; 32]) -> u128 {
    marker
        .iter()
        .fold(OFFSET, |hash, byte| (hash ^ u128::from(*byte)).wrapping_mul(PRIME))
}

fn read_marker() -> io::Result<[u8; 32]> {
    let mut marker = [0u8; 32];
    let mut input = io::stdin().lock();
    input.read_exact(&mut marker)?;
    let mut newline = [0u8; 1];
    input.read_exact(&mut newline)?;
    if newline != [b'\n'] || !marker.iter().all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()) {
        return Err(io::ErrorKind::InvalidData.into());
    }
    Ok(marker)
}

/// @cc [owner:ghuntley,label:verification;security] fsynced-pty-marker
/// The probe MUST accept exactly one bounded synthetic marker from its PTY
/// stdin, append only its digest to a private ledger under an exclusive lock,
/// sync the ledger before acknowledging, and never emit the marker or digest.
fn run() -> io::Result<()> {
    let marker = read_marker()?;
    DirBuilder::new().mode(0o700).recursive(true).create(DIRECTORY)?;
    let path = Path::new(LEDGER);
    let mut ledger = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(0o400000) // Linux O_NOFOLLOW.
        .open(path)?;
    if unsafe { flock(ledger.as_raw_fd(), 2) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let size = ledger.metadata()?.len();
    if size % 33 != 0 || size / 33 >= MAX_RECORDS {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let record = format!("{:032x}\n", digest(&marker));
    ledger.write_all(record.as_bytes())?;
    ledger.sync_all()?;
    drop(ledger);
    io::stdout().write_all(b"ACK\n")?;
    io::stdout().flush()?;
    Ok(())
}

fn main() {
    if run().is_err() {
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fnv_128_known_vector() {
        assert_eq!(digest(b"00000000000000000000000000000000"), 0x4bae73afc703da1fcce51065d5c9ef0d);
    }
}

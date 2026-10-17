//! Native FreeBSD and illumos guest boot and filesystem probes.

use crate::guest::{mmds, readiness::Boot};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::net::Ipv4Addr;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Fetch the current MMDS identity and bind it to a volatile boot UUID.
pub fn identity() -> io::Result<(Boot, Ipv4Addr, Ipv4Addr)> {
    let started = Instant::now();
    let document = loop {
        match mmds::fetch(Duration::from_secs(5)) {
            Ok(document) => break document,
            Err(error) if started.elapsed() < Duration::from_secs(600) => {
                let _ = error;
                std::thread::sleep(Duration::from_secs(2));
            }
            Err(error) => return Err(error),
        }
    };
    let address = document
        .ipv4
        .parse()
        .map_err(|_| io::Error::other("invalid guest address"))?;
    let gateway = document
        .gateway
        .parse()
        .map_err(|_| io::Error::other("invalid guest gateway"))?;
    let boot = Boot::new(
        document.placement,
        document.execution_epoch,
        document.boot_challenge,
        boot_id()?,
    )?;
    Ok((boot, address, gateway))
}

/// Read or atomically create the per-boot UUID in volatile storage.
pub fn boot_id() -> io::Result<String> {
    let path = std::env::var_os("OVERALLS_BOOT_ID")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/run/overalls/boot-id"));
    if let Ok(value) = fs::read_to_string(&path) {
        let value = value.trim().to_owned();
        if valid_uuid(&value) {
            return Ok(value);
        }
        return Err(io::Error::other("invalid native boot id"));
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut bytes = [0u8; 16];
    File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let value = format_uuid(bytes);
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    match options.open(&path) {
        Ok(mut file) => {
            file.write_all(value.as_bytes())?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            Ok(value)
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => boot_id(),
        Err(error) => Err(error),
    }
}

/// Confirm the MMDS-delivered /32 and host route without persisting command
/// output or exposing network details to diagnostics.
pub fn network_ready(address: Ipv4Addr, gateway: Ipv4Addr) -> io::Result<bool> {
    let interface = Command::new("ifconfig")
        .arg("-a")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    let route = Command::new("netstat")
        .args(["-rn"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    if !interface.status.success() || !route.status.success() {
        return Ok(false);
    }
    Ok(
        String::from_utf8_lossy(&interface.stdout).contains(&address.to_string())
            && String::from_utf8_lossy(&route.stdout).contains(&gateway.to_string()),
    )
}

/// A synced write proves that the guest root is writable before readiness.
pub fn writable_root() -> io::Result<()> {
    let directory = std::env::var_os("OVERALLS_RUN_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/run/overalls"));
    fs::create_dir_all(&directory)?;
    let path = directory.join(format!(".readiness-{}", std::process::id()));
    let mut file = File::create(&path)?;
    file.write_all(b"ready\n")?;
    file.sync_all()?;
    drop(file);
    fs::remove_file(path)
}

/// Return the immutable base bundle and managed destination for one native OS.
pub fn trust_paths(os: &str) -> io::Result<(&'static str, &'static str)> {
    match os {
        "freebsd" => Ok(("/etc/ssl/cert.pem", "/etc/ssl/cert.pem")),
        "illumos" | "solaris" => Ok((
            "/etc/openssl/certs/ca-certificates.crt",
            "/etc/openssl/certs/ca-certificates.crt",
        )),
        _ => Err(io::Error::other("unsupported native trust layout")),
    }
}

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

fn format_uuid(bytes: [u8; 16]) -> String {
    let hex = hex::encode(bytes);
    format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trust_layouts_are_closed() {
        assert_eq!(trust_paths("freebsd").unwrap().0, "/etc/ssl/cert.pem");
        assert_eq!(
            trust_paths("illumos").unwrap().0,
            "/etc/openssl/certs/ca-certificates.crt"
        );
        assert!(trust_paths("linux").is_err());
    }
}

//! One certificate installation path for ephemeral guest and persistent gateway keys.
use fs2::FileExt;
use lyra::{
    private_http,
    ssh_certificate::{self, Issued, RENEWAL_WINDOW},
    ssh_files,
};
use serde::Deserialize;
use std::fs::{self, OpenOptions};
use std::io;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Gateway {
    role: Role,
    origin: String,
    key_dir: PathBuf,
}
#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Role {
    Porsche,
    Audi,
}

#[derive(Debug, PartialEq, Eq)]
enum Installation {
    Missing,
    Current,
    Renewal,
}
fn now() -> io::Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| ssh_certificate::invalid())?
        .as_secs())
}
fn key(directory: &Path, guest: bool) -> io::Result<String> {
    let private = directory.join("ssh_host_ed25519_key");
    if !private.try_exists()? && guest {
        let status = Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-C", "", "-f"])
            .arg(&private)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;
        if !status.success() {
            return Err(ssh_certificate::invalid());
        }
    }
    ssh_files::read(&private, 16_384)?;
    let output = Command::new("ssh-keygen")
        .args(["-y", "-f"])
        .arg(&private)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    if !output.status.success() || output.stdout.len() > 4096 {
        return Err(ssh_certificate::invalid());
    }
    let public = String::from_utf8(output.stdout)
        .map_err(|_| ssh_certificate::invalid())?
        .split_whitespace()
        .take(2)
        .collect::<Vec<_>>()
        .join(" ");
    ssh_certificate::public_key(&public)?;
    Ok(public)
}
fn existing(directory: &Path, key: &str, now: u64) -> Installation {
    let result = (|| -> io::Result<bool> {
        let value: Issued = serde_json::from_slice(&ssh_files::read(
            &directory.join("certificate.json"),
            20_000,
        )?)?;
        let line = String::from_utf8(ssh_files::read(
            &directory.join("ssh_host_ed25519_key-cert.pub"),
            16_384,
        )?)
        .map_err(|_| ssh_certificate::invalid())?;
        if value.version != 1 || value.certificate != line {
            return Err(ssh_certificate::invalid());
        }
        let cert = ssh_certificate::verify(&line, &value.ca, key, &value.principal, now)?;
        Ok(cert.valid_before() > now + RENEWAL_WINDOW)
    })();
    match result {
        Ok(true) => Installation::Current,
        Ok(false) => Installation::Renewal,
        Err(_) => Installation::Missing,
    }
}
fn credential(name: &str) -> io::Result<PathBuf> {
    std::env::var_os("CREDENTIALS_DIRECTORY")
        .map(|directory| PathBuf::from(directory).join(name))
        .ok_or_else(ssh_certificate::invalid)
}
fn gateway_client(config: &Gateway) -> io::Result<reqwest::blocking::Client> {
    let url = reqwest::Url::parse(&config.origin).map_err(|_| ssh_certificate::invalid())?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || url.username() != ""
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(ssh_certificate::invalid());
    }
    let roots =
        reqwest::Certificate::from_pem_bundle(&ssh_files::read(&credential("ca.pem")?, 2_097_152)?)
            .map_err(|_| ssh_certificate::invalid())?;
    let mut client = reqwest::blocking::Client::builder()
        .use_rustls_tls()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(10))
        .tls_built_in_root_certs(false);
    for root in roots {
        client = client.add_root_certificate(root);
    }
    client.build().map_err(|_| ssh_certificate::invalid())
}
fn post(
    client: &reqwest::blocking::Client,
    url: &str,
    body: &serde_json::Value,
    token: Option<&str>,
) -> io::Result<Vec<u8>> {
    let mut request = client
        .post(url)
        .header("content-type", "application/json")
        .body(serde_json::to_vec(body)?);
    if let Some(token) = token {
        request = request.bearer_auth(token);
    }
    let response = request.send().map_err(|_| ssh_certificate::invalid())?;
    if !response.status().is_success() {
        return Err(ssh_certificate::invalid());
    }
    private_http::read_bounded(response, 20_000)
}
// @cc [owner:ghuntley,label:security;recovery] host-certificate-atomic-installation
// Installation MUST validate an authenticated response before replacing the
// certificate. Guest private keys MUST remain in /run and never enter disks.
// Failed renewal MUST retain a still-valid installed generation for retry.
fn run() -> io::Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let gateway: Option<Gateway> = match args.as_slice() {
        [] => None,
        [path] => Some(serde_json::from_slice(&ssh_files::read(
            Path::new(path),
            8192,
        )?)?),
        _ => return Err(ssh_certificate::invalid()),
    };
    let directory = gateway
        .as_ref()
        .map(|c| c.key_dir.clone())
        .unwrap_or_else(|| PathBuf::from("/run/overalls-ssh-host"));
    if !directory.try_exists()? {
        fs::create_dir(&directory)?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
    }
    let meta = fs::symlink_metadata(&directory)?;
    if !meta.is_dir() || meta.permissions().mode() & 0o077 != 0 {
        return Err(ssh_certificate::invalid());
    }
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(directory.join("certificate.lock"))?;
    lock.try_lock_exclusive()?;
    let key = key(&directory, gateway.is_none())?;
    maintain(&directory, &key, now()?, gateway.is_some(), || {
        renew(&directory, &key, gateway.as_ref())
    })
}
// @cc [owner:ghuntley,label:security;recovery] gateway-principal-from-authority
// A gateway (`authority_decides`) MUST ask Marshall on every run even while
// its installed certificate is valid: the principal is Marshall's (the
// deployment's management host), and a certificate for a previous name stays
// cryptographically valid for years. A failed request MUST keep a still-valid
// installation. Guests skip the request while their per-boot certificate is
// current.
fn maintain(
    directory: &Path,
    key: &str,
    time: u64,
    authority_decides: bool,
    renew: impl FnOnce() -> io::Result<()>,
) -> io::Result<()> {
    if !authority_decides && matches!(existing(directory, key, time), Installation::Current) {
        return Ok(());
    }
    match renew() {
        Ok(()) => Ok(()),
        Err(error) => match existing(directory, key, time.max(now()?)) {
            Installation::Current | Installation::Renewal => Ok(()),
            Installation::Missing => Err(error),
        },
    }
}
fn renew(directory: &Path, key: &str, gateway: Option<&Gateway>) -> io::Result<()> {
    let response = if let Some(config) = gateway {
        let client = gateway_client(config)?;
        let token = String::from_utf8(ssh_files::read(&credential("gateway.token")?, 128)?)
            .map_err(|_| ssh_certificate::invalid())?;
        let token = token.trim();
        let prefix = match config.role {
            Role::Audi => "audi",
            Role::Porsche => "ssh",
        };
        let root = format!("{}/api/{prefix}/v1", config.origin.trim_end_matches('/'));
        let body = serde_json::json!({"version":1,"public_key":key});
        if matches!(config.role, Role::Audi) {
            post(&client, &format!("{root}/host-key"), &body, Some(token))?;
        }
        post(
            &client,
            &format!("{root}/host-certificate"),
            &body,
            Some(token),
        )?
    } else {
        post(
            &private_http::client()?,
            "https://ssh.integration.internal/ssh/v1/host-certificate",
            &serde_json::json!({"public_key":key}),
            None,
        )?
    };
    let issued: Issued = serde_json::from_slice(&response)?;
    if issued.version != 1 {
        return Err(ssh_certificate::invalid());
    }
    ssh_certificate::verify(
        &issued.certificate,
        &issued.ca,
        key,
        &issued.principal,
        now()?,
    )?;
    ssh_files::atomic(
        &directory.join("ssh_host_ed25519_key-cert.pub"),
        issued.certificate.as_bytes(),
    )?;
    ssh_files::atomic(
        &directory.join("certificate.json"),
        &serde_json::to_vec(&issued)?,
    )?;
    Ok(())
}
fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => {
            eprintln!("SSH host certificate unavailable");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn renewal_outage_retains_valid_certificate_but_expiry_and_corruption_fail_closed() {
        let root = tempfile::tempdir().unwrap();
        let key = key(root.path(), true).unwrap();
        let ca = root.path().join("ca");
        assert!(Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-C", "", "-f"])
            .arg(&ca)
            .status()
            .unwrap()
            .success());
        assert!(Command::new("ssh-keygen")
            .args(["-q", "-s"])
            .arg(&ca)
            .args([
                "-h",
                "-I",
                "renewal",
                "-n",
                "vm.example.test",
                "-V",
                "-5m:+3650d"
            ])
            .arg(root.path().join("ssh_host_ed25519_key.pub"))
            .status()
            .unwrap()
            .success());
        let line = fs::read_to_string(root.path().join("ssh_host_ed25519_key-cert.pub")).unwrap();
        let issued = Issued {
            version: 1,
            certificate: line.clone(),
            principal: "vm.example.test".into(),
            ca: fs::read_to_string(ca.with_extension("pub"))
                .unwrap()
                .trim()
                .into(),
        };
        ssh_files::atomic(
            &root.path().join("certificate.json"),
            &serde_json::to_vec(&issued).unwrap(),
        )
        .unwrap();
        let cert =
            ssh_certificate::verify(&line, &issued.ca, &key, &issued.principal, now().unwrap())
                .unwrap();
        assert_eq!(
            existing(root.path(), &key, cert.valid_before() - RENEWAL_WINDOW - 1),
            Installation::Current
        );
        assert_eq!(
            existing(root.path(), &key, cert.valid_before() - RENEWAL_WINDOW),
            Installation::Renewal
        );
        maintain(root.path(), &key, now().unwrap(), false, || {
            panic!("current guest certificates need no authority request")
        })
        .unwrap();
        // A gateway asks even while current (its principal may have moved),
        // and an unavailable authority keeps the valid installation.
        let mut asked = false;
        maintain(root.path(), &key, now().unwrap(), true, || {
            asked = true;
            Err(ssh_certificate::invalid())
        })
        .unwrap();
        assert!(asked);
        for gateway in [false, true] {
            maintain(root.path(), &key, cert.valid_before() - 1, gateway, || {
                Err(ssh_certificate::invalid())
            })
            .unwrap();
            assert!(
                maintain(root.path(), &key, cert.valid_before(), gateway, || Err(
                    ssh_certificate::invalid()
                ))
                .is_err()
            );
        }
        assert_eq!(
            fs::read_to_string(root.path().join("ssh_host_ed25519_key-cert.pub")).unwrap(),
            line
        );
        fs::write(root.path().join("ssh_host_ed25519_key-cert.pub"), "broken").unwrap();
        assert!(maintain(root.path(), &key, now().unwrap(), false, || Err(
            ssh_certificate::invalid()
        ))
        .is_err());
    }
}

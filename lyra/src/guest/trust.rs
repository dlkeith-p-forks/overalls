//! Boot-bound public CA delivery (vsock port 1030), shared by the Windows trust
//! daemon (ADR-0171; the Linux `overalls-trustd` keeps its own copy of the
//! validation until it is folded in).
//!
//! Lilly frames one JSON request (4-byte big-endian length, at most 1 MiB)
//! naming this boot and carrying up to 32 PEM roots with their sorted
//! fingerprint digest; the guest installs exactly that set and answers with an
//! `installed` receipt bound to the same boot, nonce and digest. A failed or
//! partial installation never acknowledges.

use rustls_pki_types::pem::PemObject;
use rustls_pki_types::CertificateDer;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::{self, Read, Write};

/// Vsock port Lilly dials with the trust request.
pub const PORT: u32 = 1030;
pub const MAX_FRAME: usize = 1_048_576;
pub const MAX_ROOTS: usize = 32;
pub const MAX_CERT: usize = 16_384;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u8,
    pub placement_id: String,
    pub execution_epoch: u64,
    pub boot_challenge: String,
    pub nonce: String,
    pub bundle_digest: String,
    pub roots: Vec<String>,
}

#[derive(Serialize)]
pub struct Receipt<'a> {
    pub version: u8,
    pub state: &'static str,
    pub placement_id: &'a str,
    pub execution_epoch: u64,
    pub boot_challenge: &'a str,
    pub boot_id: &'a str,
    pub nonce: &'a str,
    pub bundle_digest: &'a str,
}

/// This boot's identity, as the readiness module knows it.
pub use crate::guest::readiness::Boot;

fn valid_hex(value: &str, size: usize) -> bool {
    value.len() == size && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// One PEM certificate body as DER.
pub fn der(pem: &str) -> io::Result<Vec<u8>> {
    CertificateDer::from_pem_slice(pem.as_bytes())
        .map(|certificate| certificate.to_vec())
        .map_err(|_| io::Error::other("invalid trust certificate"))
}

/// @cc [owner:ghuntley,label:security;recovery] guest-trust-exact-boot-shared
/// validate MUST accept only a version-1 request naming this exact boot, with a
/// 64-hex nonce and bundle digest, one to 32 unique PEM certificates of at most
/// 16 KiB each that parse as certificates and contain no private key, whose
/// sorted SHA-256 fingerprint concatenation hashes to the digest. It returns the
/// DER of every root in request order.
pub fn validate(request: &Request, boot: &Boot) -> io::Result<Vec<Vec<u8>>> {
    if request.version != 1
        || request.placement_id != boot.placement_id
        || request.execution_epoch != boot.execution_epoch
        || request.boot_challenge != boot.boot_challenge
        || !valid_hex(&request.nonce, 64)
        || !valid_hex(&request.bundle_digest, 64)
        || request.roots.is_empty()
        || request.roots.len() > MAX_ROOTS
    {
        return Err(io::Error::other("invalid trust request"));
    }
    let mut fingerprints = Vec::with_capacity(request.roots.len());
    let mut ders = Vec::with_capacity(request.roots.len());
    for pem in &request.roots {
        if pem.len() > MAX_CERT
            || !pem.starts_with("-----BEGIN CERTIFICATE-----\n")
            || !pem.trim_end().ends_with("-----END CERTIFICATE-----")
            || pem.matches("-----BEGIN CERTIFICATE-----").count() != 1
            || pem.matches("-----END CERTIFICATE-----").count() != 1
            || pem.contains("PRIVATE KEY")
        {
            return Err(io::Error::other("invalid trust certificate"));
        }
        ders.push(der(pem)?);
        fingerprints.push(Sha256::digest(pem.as_bytes()).to_vec());
    }
    fingerprints.sort();
    if fingerprints.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err(io::Error::other("duplicate trust certificate"));
    }
    let digest = hex::encode(Sha256::digest(fingerprints.concat()));
    if digest != request.bundle_digest {
        return Err(io::Error::other("trust digest mismatch"));
    }
    Ok(ders)
}

/// The PEM bundle Git and HTTP clients read: the image's base bundle followed
/// by every delivered root, each terminated by one newline.
pub fn bundle(base: &[u8], roots: &[String]) -> io::Result<Vec<u8>> {
    if base.len() > MAX_FRAME {
        return Err(io::Error::other("system trust unavailable"));
    }
    let mut bytes = base.to_vec();
    if !bytes.ends_with(b"\n") {
        bytes.push(b'\n');
    }
    for root in roots {
        bytes.extend_from_slice(root.as_bytes());
        if !root.ends_with('\n') {
            bytes.push(b'\n');
        }
    }
    Ok(bytes)
}

/// Read one length-prefixed request frame.
pub fn read_frame(stream: &mut impl Read) -> io::Result<Request> {
    let mut header = [0u8; 4];
    stream.read_exact(&mut header)?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > MAX_FRAME {
        return Err(io::Error::other("invalid frame"));
    }
    let mut body = vec![0; length];
    stream.read_exact(&mut body)?;
    serde_json::from_slice(&body).map_err(|_| io::Error::other("invalid frame"))
}

/// Write one length-prefixed receipt frame.
pub fn write_frame(stream: &mut impl Write, receipt: &Receipt<'_>) -> io::Result<()> {
    let body = serde_json::to_vec(receipt)?;
    stream.write_all(&(body.len() as u32).to_be_bytes())?;
    stream.write_all(&body)
}

/// The `installed` receipt for a validated request.
pub fn receipt<'a>(request: &'a Request, boot: &'a Boot) -> Receipt<'a> {
    Receipt {
        version: 1,
        state: "installed",
        placement_id: &boot.placement_id,
        execution_epoch: boot.execution_epoch,
        boot_challenge: &boot.boot_challenge,
        boot_id: &boot.boot_id,
        nonce: &request.nonce,
        bundle_digest: &request.bundle_digest,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // A self-signed test certificate (RSA 2048, "overalls trust fixture").
    const ROOT: &str = "-----BEGIN CERTIFICATE-----\nMIIBhTCCASsCFHTNYy7Zrt1xYj0q6ir7R5mIl0U7MAoGCCqGSM49BAMCMBwxGjAY\nBgNVBAMMEWtpdHRlbnMtZml4dHVyZS1jYTAeFw0yNDAxMDEwMDAwMDBaFw0zNDAx\nMDEwMDAwMDBaMBwxGjAYBgNVBAMMEWtpdHRlbnMtZml4dHVyZS1jYTBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABEvI4qYwOCtPYwgM9hEnl0mVsE8ia1EO2qa5bYvX\nBP6nZKtq5Q9HcGm4wzA0Yu9jCmHfC6BAfxvZ6T1C1Vrv2WqjUzBRMB0GA1UdDgQW\nBBS6GpFyMGMrXoE1Y0p0bUIuSwZ4qTAfBgNVHSMEGDAWgBS6GpFyMGMrXoE1Y0p0\nbUIuSwZ4qTAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIQDgnzqS\nL3S1KQrkqiVhgKWxnSLpV5oAAJ5a7n6tKqGT3gIgTdoi7kXfQ3g0ZJm2Pq1W3Zm3\nmYQZd4vYwUe2vO5JGRQ=\n-----END CERTIFICATE-----\n";

    fn boot() -> Boot {
        Boot::new(
            "dddddddd-dddd-4ddd-8ddd-000000000201".into(),
            7,
            "b".repeat(64),
            "0f0e0d0c-0b0a-4908-8706-050403020100".into(),
        )
        .unwrap()
    }

    fn request(roots: Vec<String>) -> Request {
        let mut fingerprints: Vec<Vec<u8>> = roots
            .iter()
            .map(|pem| Sha256::digest(pem.as_bytes()).to_vec())
            .collect();
        fingerprints.sort();
        Request {
            version: 1,
            placement_id: "dddddddd-dddd-4ddd-8ddd-000000000201".into(),
            execution_epoch: 7,
            boot_challenge: "b".repeat(64),
            nonce: "c".repeat(64),
            bundle_digest: hex::encode(Sha256::digest(fingerprints.concat())),
            roots,
        }
    }

    #[test]
    fn frames_round_trip_and_bound() {
        let request = request(vec![ROOT.to_string()]);
        let body = serde_json::to_vec(&serde_json::json!({
            "version": 1, "placement_id": request.placement_id, "execution_epoch": 7,
            "boot_challenge": request.boot_challenge, "nonce": request.nonce,
            "bundle_digest": request.bundle_digest, "roots": request.roots
        }))
        .unwrap();
        let mut framed = (body.len() as u32).to_be_bytes().to_vec();
        framed.extend_from_slice(&body);
        let parsed = read_frame(&mut framed.as_slice()).unwrap();
        assert_eq!(parsed.roots.len(), 1);
        assert!(read_frame(&mut [0u8, 0, 0, 0].as_slice()).is_err());
        assert!(read_frame(&mut (MAX_FRAME as u32 + 1).to_be_bytes().as_slice()).is_err());
        let boot = boot();
        let mut out = Vec::new();
        write_frame(&mut out, &receipt(&parsed, &boot)).unwrap();
        let length = u32::from_be_bytes(out[..4].try_into().unwrap()) as usize;
        let value: serde_json::Value = serde_json::from_slice(&out[4..4 + length]).unwrap();
        assert_eq!(value["state"], "installed");
        assert_eq!(value["boot_id"], "0f0e0d0c-0b0a-4908-8706-050403020100");
        assert_eq!(value["nonce"], "c".repeat(64));
    }

    #[test]
    fn validation_binds_boot_digest_and_certificate_shape() {
        let boot = boot();
        let good = request(vec![ROOT.to_string()]);
        let ders = validate(&good, &boot).unwrap();
        assert_eq!(ders.len(), 1);
        assert_eq!(ders[0][0], 0x30);
        let mut other_boot = boot.clone();
        other_boot.execution_epoch = 8;
        assert!(validate(&good, &other_boot).is_err());
        let mut wrong_digest = request(vec![ROOT.to_string()]);
        wrong_digest.bundle_digest = "0".repeat(64);
        assert!(validate(&wrong_digest, &boot).is_err());
        assert!(validate(&request(vec![ROOT.to_string(), ROOT.to_string()]), &boot).is_err());
        assert!(validate(&request(vec![]), &boot).is_err());
        assert!(validate(
            &request(vec![
                ROOT.replace("CERTIFICATE-----\nMIIB", "CERTIFICATE-----\n!!IB")
            ]),
            &boot
        )
        .is_err());
        assert!(validate(
            &request(vec![format!("{ROOT}-----BEGIN PRIVATE KEY-----\n")]),
            &boot
        )
        .is_err());
        let bundle = bundle(
            b"-----BEGIN CERTIFICATE-----\nbase\n-----END CERTIFICATE-----",
            &good.roots,
        )
        .unwrap();
        assert!(bundle.starts_with(
            b"-----BEGIN CERTIFICATE-----\nbase\n-----END CERTIFICATE-----\n-----BEGIN"
        ));
        assert!(bundle.ends_with(b"-----END CERTIFICATE-----\n"));
    }
}

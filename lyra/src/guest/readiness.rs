//! Guest boot readiness evidence (vsock port 1024), shared by the Windows
//! readiness daemon and usable by any agent that answers Lilly's poll
//! (ADR-0171; the Linux guests keep `nix/packages/guest/readiness.py`).
//!
//! Lilly dials port 1024, reads one JSON line of at most 512 bytes and verifies
//! it against the boot it launched. The line binds this boot's placement,
//! execution epoch and boot challenge with the kernel (or volatile registry)
//! boot UUID, and is sent only to host CID 2 after every live probe succeeded.

use serde::Serialize;
use std::io;

/// Vsock port Lilly polls.
pub const PORT: u32 = 1024;
/// Lilly refuses longer lines.
pub const MAXIMUM_LINE: usize = 512;

/// This boot's identity as Lilly delivered it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Boot {
    pub placement_id: String,
    pub execution_epoch: u64,
    pub boot_challenge: String,
    pub boot_id: String,
}

#[derive(Serialize)]
struct Response<'a> {
    version: u8,
    state: &'static str,
    placement_id: &'a str,
    execution_epoch: u64,
    boot_challenge: &'a str,
    boot_id: &'a str,
}

fn valid_hex(value: &str, size: usize) -> bool {
    value.len() == size
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
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

impl Boot {
    /// @cc [owner:ghuntley,label:security] readiness-boot-identity-validated
    /// A boot MUST carry a lowercase UUID placement, a positive epoch, a 64-hex
    /// lowercase challenge and a lowercase UUID boot identity; anything else is
    /// refused before a response can exist.
    pub fn new(
        placement_id: String,
        execution_epoch: u64,
        boot_challenge: String,
        boot_id: String,
    ) -> io::Result<Self> {
        if !valid_uuid(&placement_id)
            || execution_epoch == 0
            || !valid_hex(&boot_challenge, 64)
            || !valid_uuid(&boot_id)
        {
            return Err(io::Error::other("invalid boot identity"));
        }
        Ok(Self {
            placement_id,
            execution_epoch,
            boot_challenge,
            boot_id,
        })
    }

    /// @cc [owner:ghuntley,label:protocol] readiness-response-closed-line
    /// The response MUST be exactly the six-key version-1 `ready` object
    /// (`OverallsProtocol.Readiness.response/1`) as one newline-terminated line
    /// of at most 512 bytes.
    pub fn response(&self) -> io::Result<Vec<u8>> {
        let mut line = serde_json::to_vec(&Response {
            version: 1,
            state: "ready",
            placement_id: &self.placement_id,
            execution_epoch: self.execution_epoch,
            boot_challenge: &self.boot_challenge,
            boot_id: &self.boot_id,
        })?;
        line.push(b'\n');
        if line.len() > MAXIMUM_LINE {
            return Err(io::Error::other("oversized readiness response"));
        }
        Ok(line)
    }
}

/// A live check the daemon runs before every answer.
pub trait Probe {
    /// `Ok(true)` when the guest is ready; `Ok(false)` or an error withholds the answer.
    fn ready(&mut self) -> io::Result<bool>;
}

/// @cc [owner:ghuntley,label:security] readiness-host-only-after-probes
/// answer MUST write the response only when the peer is host CID 2 and every
/// probe succeeded; any other peer or a failed probe gets nothing.
pub fn answer(
    peer_cid: u32,
    host_cid: u32,
    boot: &Boot,
    probe: &mut impl Probe,
) -> io::Result<Option<Vec<u8>>> {
    if peer_cid != host_cid {
        return Ok(None);
    }
    if probe.ready()? {
        Ok(Some(boot.response()?))
    } else {
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixed(bool);
    impl Probe for Fixed {
        fn ready(&mut self) -> io::Result<bool> {
            Ok(self.0)
        }
    }

    fn boot() -> Boot {
        Boot::new(
            "dddddddd-dddd-4ddd-8ddd-000000000201".into(),
            7,
            "b".repeat(64),
            "0f0e0d0c-0b0a-4908-8706-050403020100".into(),
        )
        .unwrap()
    }

    #[test]
    fn response_is_the_closed_six_key_line() {
        let line = boot().response().unwrap();
        assert!(line.ends_with(b"\n") && line.len() <= MAXIMUM_LINE);
        let value: serde_json::Value = serde_json::from_slice(&line).unwrap();
        let object = value.as_object().unwrap();
        assert_eq!(object.len(), 6);
        assert_eq!(object["version"], 1);
        assert_eq!(object["state"], "ready");
        assert_eq!(
            object["placement_id"],
            "dddddddd-dddd-4ddd-8ddd-000000000201"
        );
        assert_eq!(object["execution_epoch"], 7);
        assert_eq!(object["boot_challenge"], "b".repeat(64));
        assert_eq!(object["boot_id"], "0f0e0d0c-0b0a-4908-8706-050403020100");
    }

    #[test]
    fn identity_and_peer_checks_fail_closed() {
        assert!(Boot::new(
            "DDDDDDDD-dddd-4ddd-8ddd-000000000201".into(),
            1,
            "b".repeat(64),
            "0f0e0d0c-0b0a-4908-8706-050403020100".into()
        )
        .is_err());
        assert!(Boot::new(
            "dddddddd-dddd-4ddd-8ddd-000000000201".into(),
            0,
            "b".repeat(64),
            "0f0e0d0c-0b0a-4908-8706-050403020100".into()
        )
        .is_err());
        assert!(Boot::new(
            "dddddddd-dddd-4ddd-8ddd-000000000201".into(),
            1,
            "B".repeat(64),
            "0f0e0d0c-0b0a-4908-8706-050403020100".into()
        )
        .is_err());
        assert!(Boot::new(
            "dddddddd-dddd-4ddd-8ddd-000000000201".into(),
            1,
            "b".repeat(64),
            "not-a-uuid".into()
        )
        .is_err());
        let boot = boot();
        assert!(answer(3, 2, &boot, &mut Fixed(true)).unwrap().is_none());
        assert!(answer(2, 2, &boot, &mut Fixed(false)).unwrap().is_none());
        assert!(answer(2, 2, &boot, &mut Fixed(true)).unwrap().is_some());
    }
}

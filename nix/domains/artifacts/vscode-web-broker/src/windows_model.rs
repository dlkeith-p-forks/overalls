//! Windows worker identity and recovery policy. This grants no image capability.

use crate::{Binding, Boot, Descriptor, Preface, Refusal, validate};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Complete S-1-5-21 account SID syntax; native SAM lookup establishes locality.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct AccountSid(Vec<u8>);

impl AccountSid {
    /// @cc [owner:ghuntley,label:security] windows-editor-local-account-sid
    /// Account custody MUST use a complete S-1-5-21 SID with an ordinary
    /// account RID. SYSTEM, built-in groups and partial SIDs MUST NOT become
    /// editor account identities. Only native SAM lookup establishes locality.
    pub fn parse(bytes: &[u8]) -> Result<Self, Refusal> {
        if bytes.len() != 28
            || bytes[..8] != [1, 5, 0, 0, 0, 0, 0, 5]
            || u32::from_le_bytes(bytes[8..12].try_into().map_err(|_| Refusal::Account)?) != 21
            || u32::from_le_bytes(bytes[24..28].try_into().map_err(|_| Refusal::Account)?) < 1000
        {
            return Err(Refusal::Account);
        }
        Ok(Self(bytes.to_vec()))
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

/// Exact account, physical execution, package and browser-origin launch identity.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct WorkerIdentity {
    uid: u32,
    username: String,
    guest_account_id: String,
    placement_id: String,
    execution_epoch: u64,
    sid: AccountSid,
    descriptor: Descriptor,
    origin: String,
    webview_template: String,
}

impl WorkerIdentity {
    /// @cc [owner:ghuntley,label:security] windows-editor-identity-closed-admission
    /// A Windows worker identity MUST pass the existing exact boot/package/
    /// origin admission and use the canonical u<uid> roster name. A caller
    /// hint or a valid SID alone MUST NOT create a worker identity.
    pub fn admitted(
        preface: &Preface,
        boot: &Boot,
        descriptor: &Descriptor,
        sid: AccountSid,
    ) -> Result<Self, Refusal> {
        validate(preface, boot, descriptor)?;
        let Binding {
            uid,
            username,
            guest_account_id,
            placement_id,
            execution_epoch,
            editor_origin,
            ..
        } = &preface.binding;
        if username != &format!("u{uid}") {
            return Err(Refusal::Account);
        }
        Ok(Self {
            uid: *uid,
            username: username.clone(),
            guest_account_id: guest_account_id.clone(),
            placement_id: placement_id.clone(),
            execution_epoch: *execution_epoch,
            sid,
            descriptor: descriptor.clone(),
            origin: editor_origin.clone(),
            webview_template: crate::webview_template(&preface.binding)?,
        })
    }

    pub fn username(&self) -> &str {
        &self.username
    }
    pub fn uid(&self) -> u32 {
        self.uid
    }
    pub fn guest_account_id(&self) -> &str {
        &self.guest_account_id
    }
    pub fn placement_id(&self) -> &str {
        &self.placement_id
    }
    pub fn execution_epoch(&self) -> u64 {
        self.execution_epoch
    }
    pub fn sid(&self) -> &AccountSid {
        &self.sid
    }
    pub fn origin(&self) -> &str {
        &self.origin
    }
    pub fn descriptor(&self) -> &Descriptor {
        &self.descriptor
    }
    pub fn webview_template(&self) -> &str {
        &self.webview_template
    }

    pub fn key(&self) -> String {
        // Struct fields have a fixed serialization order and no unchecked values.
        let mut hash = Sha256::new();
        hash.update(b"overalls-windows-editor-worker-v1\0");
        hash.update(serde_json::to_vec(self).expect("closed identity serialization"));
        hash.finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }

    pub fn pipe_name(&self) -> String {
        format!(r"\\.\pipe\overalls-editor-{}-{}", self.uid, self.key())
    }

    pub fn job_name(&self) -> String {
        format!(r"Global\overalls-editor-{}-{}", self.uid, self.key())
    }
}

/// Process creation time disambiguates a retained kernel process from PID reuse.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ProcessIdentity {
    pub pid: u32,
    pub created: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PipePeer {
    pub process: ProcessIdentity,
    pub sid: AccountSid,
    pub in_expected_job: bool,
    pub exact_executable: bool,
}

/// @cc [owner:ghuntley,label:security] windows-editor-pipe-kernel-custody
/// A pipe MUST be reusable only when its server has the exact retained PID and
/// creation time, account SID, named-job membership and configured executable.
/// Matching a name, PID alone or same-account SID alone MUST NOT authorize it.
pub fn verify_peer(
    identity: &WorkerIdentity,
    expected: ProcessIdentity,
    peer: &PipePeer,
) -> Result<(), Refusal> {
    if expected.pid == 0
        || expected.created == 0
        || peer.process != expected
        || peer.sid != identity.sid
        || !peer.in_expected_job
        || !peer.exact_executable
    {
        Err(Refusal::Custody)
    } else {
        Ok(())
    }
}

/// Missing metadata never authorizes destructive cleanup of a possible worker.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecoveryDecision {
    Start,
    Reuse,
    StopOwnedThenStart,
    Refuse,
}

/// @cc [owner:ghuntley,label:recovery] windows-editor-recovery-no-foreign-cleanup
/// Recovery MUST reuse only exact identities with proven pipe custody. A
/// mismatched owned worker may be stopped only after root-owned job/process
/// custody is established. Incomplete or foreign metadata MUST refuse without
/// terminating a process, removing a pipe or deleting personal data.
pub fn recovery_decision(
    exists: bool,
    system_owned_job: bool,
    exact_identity: bool,
    proven_peer: bool,
) -> RecoveryDecision {
    match (exists, system_owned_job, exact_identity, proven_peer) {
        (false, _, _, _) => RecoveryDecision::Start,
        (true, true, true, true) => RecoveryDecision::Reuse,
        (true, true, false, true) => RecoveryDecision::StopOwnedThenStart,
        _ => RecoveryDecision::Refuse,
    }
}

/// A configured local drive path; UNC, device and alternate-stream paths refuse.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocalPath(String);

impl LocalPath {
    pub fn parse(value: &str) -> Result<Self, Refusal> {
        let bytes = value.as_bytes();
        if bytes.len() == 3 && bytes[0].is_ascii_alphabetic() && &bytes[1..] == b":\\" {
            return Ok(Self(value.to_owned()));
        }
        if bytes.len() < 4
            || bytes.len() > 4096
            || !bytes[0].is_ascii_alphabetic()
            || &bytes[1..3] != b":\\"
            || value[3..].contains([':', '/', '"', '\0', '\r', '\n'])
            || value[3..].split('\\').any(|part| {
                part.is_empty()
                    || part == "."
                    || part == ".."
                    || part.ends_with(['.', ' '])
                    || dos_device(part)
            })
        {
            return Err(Refusal::Package);
        }
        Ok(Self(value.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

fn dos_device(component: &str) -> bool {
    let base = component
        .split('.')
        .next()
        .unwrap_or_default()
        .to_ascii_uppercase();
    matches!(
        base.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
    ) || base
        .strip_prefix("COM")
        .or_else(|| base.strip_prefix("LPT"))
        .is_some_and(|suffix| {
            matches!(
                suffix,
                "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
            )
        })
}

/// Windows C-runtime quoting; the process is created directly, without a shell.
pub fn command_line(arguments: &[String]) -> Result<Vec<u16>, Refusal> {
    let mut command = String::new();
    for argument in arguments {
        if argument.contains('\0') {
            return Err(Refusal::Package);
        }
        if !command.is_empty() {
            command.push(' ');
        }
        command.push('"');
        let mut slashes = 0;
        for character in argument.chars() {
            if character == '\\' {
                slashes += 1;
                continue;
            }
            if character == '"' {
                command.extend(std::iter::repeat_n('\\', slashes * 2 + 1));
            } else {
                command.extend(std::iter::repeat_n('\\', slashes));
            }
            slashes = 0;
            command.push(character);
        }
        command.extend(std::iter::repeat_n('\\', slashes * 2));
        command.push('"');
    }
    let mut wide: Vec<u16> = command.encode_utf16().collect();
    if wide.is_empty() || wide.len() >= 32767 {
        return Err(Refusal::Package);
    }
    wide.push(0);
    Ok(wide)
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn sid(rid: u32) -> AccountSid {
        let mut bytes = vec![1, 5, 0, 0, 0, 0, 0, 5];
        for value in [21_u32, 1, 2, 3, rid] {
            bytes.extend(value.to_le_bytes());
        }
        AccountSid::parse(&bytes).unwrap()
    }

    fn identity() -> WorkerIdentity {
        WorkerIdentity {
            uid: 200001,
            username: "u200001".to_owned(),
            guest_account_id: "11111111-1111-4111-8111-111111111111".to_owned(),
            placement_id: "22222222-2222-4222-8222-222222222222".to_owned(),
            execution_epoch: 1,
            sid: sid(1001),
            descriptor: Descriptor {
                protocol: 1,
                commit: "a".repeat(40),
                release: "b".repeat(64),
            },
            origin: "https://editor.apps.test".to_owned(),
            webview_template: "https://{{uuid}}.apps.test/code-assets/test/".to_owned(),
        }
    }

    proptest! {
        #[test]
        fn any_foreign_pid_or_creation_time_refuses(pid in 1_u32..u32::MAX, created in 1_u64..u64::MAX) {
            let identity = identity();
            let expected = ProcessIdentity { pid, created };
            let mut peer = PipePeer { process: expected, sid: identity.sid.clone(), in_expected_job: true, exact_executable: true };
            prop_assert_eq!(verify_peer(&identity, expected, &peer), Ok(()));
            peer.process.pid = pid.wrapping_add(1);
            prop_assert_eq!(verify_peer(&identity, expected, &peer), Err(Refusal::Custody));
            peer.process = ProcessIdentity { pid, created: created.wrapping_add(1) };
            prop_assert_eq!(verify_peer(&identity, expected, &peer), Err(Refusal::Custody));
        }

        #[test]
        fn identity_changes_never_reuse_old_pipe_or_job(epoch in 2_u64..u64::MAX, rid in 1002_u32..u32::MAX) {
            let first = identity();
            let mut next = first.clone(); next.execution_epoch = epoch;
            prop_assert_ne!(first.pipe_name(), next.pipe_name());
            prop_assert_ne!(first.job_name(), next.job_name());
            next = first.clone(); next.sid = sid(rid);
            prop_assert_ne!(first.key(), next.key());
        }

        #[test]
        fn incomplete_recovery_custody_never_stops_workers(exact in any::<bool>(), peer in any::<bool>()) {
            prop_assert_eq!(recovery_decision(true, false, exact, peer), RecoveryDecision::Refuse);
            prop_assert_eq!(recovery_decision(true, exact, peer, false), RecoveryDecision::Refuse);
        }

        #[test]
        fn every_truncated_local_sid_refuses(length in 0_usize..28) {
            prop_assert_eq!(AccountSid::parse(&sid(1001).as_bytes()[..length]), Err(Refusal::Account));
        }
    }

    #[test]
    fn same_account_pipe_requires_job_and_executable_custody() {
        let identity = identity();
        let expected = ProcessIdentity {
            pid: 7,
            created: 99,
        };
        let peer = PipePeer {
            process: expected,
            sid: identity.sid.clone(),
            in_expected_job: true,
            exact_executable: true,
        };
        assert_eq!(
            verify_peer(
                &identity,
                expected,
                &PipePeer {
                    sid: sid(1002),
                    ..peer.clone()
                }
            ),
            Err(Refusal::Custody)
        );
        assert_eq!(
            verify_peer(
                &identity,
                expected,
                &PipePeer {
                    in_expected_job: false,
                    ..peer.clone()
                }
            ),
            Err(Refusal::Custody)
        );
        assert_eq!(
            verify_peer(
                &identity,
                expected,
                &PipePeer {
                    exact_executable: false,
                    ..peer
                }
            ),
            Err(Refusal::Custody)
        );
        assert_eq!(
            recovery_decision(true, true, false, true),
            RecoveryDecision::StopOwnedThenStart
        );
    }

    #[test]
    fn device_relative_alternate_stream_and_ambiguous_paths_refuse() {
        assert!(LocalPath::parse(r"C:\Program Files\Overalls\node.exe").is_ok());
        for value in [
            r"node.exe",
            r"C:node.exe",
            r"\\host\share\node.exe",
            r"\\?\C:\node.exe",
            r"C:\node.exe:stream",
            r"C:\a\..\node.exe",
            r"C:\a.\node.exe",
            r"C:\a \node.exe",
            r"C:\a\\node.exe",
            r"C:\NUL",
            r"C:\CON.exe",
            r"C:\COM¹.exe",
        ] {
            assert_eq!(LocalPath::parse(value), Err(Refusal::Package));
        }
    }

    #[test]
    fn quoted_paths_and_trailing_slashes_have_exact_windows_escaping() {
        let command = command_line(&[
            r"C:\Program Files\node.exe".to_owned(),
            "a\"b".to_owned(),
            "x\\".to_owned(),
            "".to_owned(),
        ])
        .unwrap();
        assert_eq!(
            String::from_utf16(&command[..command.len() - 1]).unwrap(),
            "\"C:\\Program Files\\node.exe\" \"a\\\"b\" \"x\\\\\" \"\""
        );
        assert_eq!(command_line(&["x\0y".to_owned()]), Err(Refusal::Package));
    }
}

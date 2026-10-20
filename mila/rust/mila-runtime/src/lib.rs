//! Pure runtime state machines for idempotent Mila mutations.

use mila_model::RequestId;
use mila_protocol::{ReceiptStatus, Reply};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

/// The externally observable phase of one mutation request.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum MutationPhase {
    Submitted,
    Uncertain,
    Accepted,
    Succeeded,
    Failed,
    Refused,
}

impl MutationPhase {
    pub const fn terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Failed | Self::Refused)
    }
}

/// Immutable state for a mutation submitted at most once.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MutationTracker {
    pub request_id: RequestId,
    pub phase: MutationPhase,
    pub polls: u32,
    pub operation_id: Option<String>,
    pub error: Option<String>,
    pub result: Value,
}

impl MutationTracker {
    /// Allocates a tracker before any network submission.
    ///
    /// @cc [owner:ghuntley,label:protocol;security] mila-runtime-mutation-once
    /// A tracker MUST retain one request id for its lifetime; uncertainty transitions
    /// to polling and MUST never create a second submission id.
    pub fn submitted(request_id: RequestId) -> Self {
        Self {
            request_id,
            phase: MutationPhase::Submitted,
            polls: 0,
            operation_id: None,
            error: None,
            result: Value::Object(Default::default()),
        }
    }

    /// Records a poll issued against the original request id.
    pub fn polled(&mut self) -> Result<(), RuntimeError> {
        if self.phase.terminal() {
            return Ok(());
        }
        self.polls = self.polls.saturating_add(1);
        Ok(())
    }

    /// Marks the submission outcome unknown without permitting resubmission.
    pub fn uncertain(&mut self) {
        if !self.phase.terminal() {
            self.phase = MutationPhase::Uncertain;
        }
    }

    /// Applies a receipt or refusal; terminal states absorb late replies.
    pub fn observe(&mut self, reply: Reply) -> Result<(), RuntimeError> {
        if self.phase.terminal() {
            return Ok(());
        }
        match reply {
            Reply::Receipt(receipt) => {
                if receipt.request_id != self.request_id {
                    return Err(RuntimeError::RequestMismatch);
                }
                if let (Some(previous), Some(current)) = (&self.operation_id, receipt.operation_id)
                {
                    if previous != &current.to_string() {
                        return Err(RuntimeError::OperationMismatch);
                    }
                }
                self.operation_id = receipt.operation_id.map(|value| value.to_string());
                self.result = receipt.result;
                self.phase = match receipt.status {
                    ReceiptStatus::Accepted => MutationPhase::Accepted,
                    ReceiptStatus::Succeeded => MutationPhase::Succeeded,
                    ReceiptStatus::Failed | ReceiptStatus::Superseded => MutationPhase::Failed,
                };
            }
            Reply::Error { error, .. } => {
                self.error = Some(error);
                self.phase = MutationPhase::Refused;
            }
            Reply::Read(_) => self.uncertain(),
        }
        Ok(())
    }

    /// Returns the command the caller may issue next.
    pub const fn next_action(&self) -> NextAction {
        if self.phase.terminal() {
            NextAction::Done
        } else {
            NextAction::Poll
        }
    }
}

/// Runtime work required after observing a tracker.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NextAction {
    Poll,
    Done,
}

/// Runtime state machine failures.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum RuntimeError {
    #[error("receipt request id does not match the tracker")]
    RequestMismatch,
    #[error("receipt operation id changed")]
    OperationMismatch,
    #[error("invalid snapshot")]
    InvalidSnapshot,
    #[error("snapshot is too large")]
    SnapshotTooLarge,
    #[error("snapshot belongs to another deployment")]
    SnapshotDeploymentMismatch,
    #[error("invalid push registration")]
    InvalidPushRegistration,
    #[error("invalid push poke")]
    InvalidPoke,
    #[error("command is invalid or exceeds bounds")]
    InvalidCommand,
    #[error("mutation was already submitted")]
    AlreadySubmitted,
    #[error("mutation has not been submitted")]
    NotSubmitted,
    #[error("session backend failed")]
    Backend,
}

/// Maximum number of machines retained by an offline snapshot.
pub const MAX_SNAPSHOT_MACHINES: usize = 500;
/// Maximum encoded snapshot size accepted from disk.
pub const MAX_SNAPSHOT_BYTES: usize = 1 << 20;

/// A closed, privacy-preserving machine representation suitable for caching.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SnapshotMachine {
    pub id: String,
    pub name: String,
    pub desired_state: String,
    pub observed_state: Option<String>,
    pub pinned: bool,
    pub owner: Option<String>,
    pub read: bool,
    pub write: bool,
    pub manage: bool,
}

/// A complete machine listing for one deployment.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MachineSnapshot {
    pub version: u8,
    pub host: String,
    pub port: Option<u16>,
    pub saved_at: u64,
    pub machines: Vec<SnapshotMachine>,
}

impl MachineSnapshot {
    pub const VERSION: u8 = 1;

    /// Constructs a bounded snapshot, retaining deterministic machine order.
    pub fn new(
        host: String,
        port: Option<u16>,
        saved_at: u64,
        mut machines: Vec<SnapshotMachine>,
    ) -> Result<Self, RuntimeError> {
        validate_host(&host)?;
        machines.sort_by(|a, b| {
            (std::cmp::Reverse(a.pinned), a.name.as_str(), a.id.as_str()).cmp(&(
                std::cmp::Reverse(b.pinned),
                b.name.as_str(),
                b.id.as_str(),
            ))
        });
        machines.truncate(MAX_SNAPSHOT_MACHINES);
        Ok(Self {
            version: Self::VERSION,
            host,
            port,
            saved_at,
            machines,
        })
    }

    /// Encodes only the closed snapshot schema.
    pub fn encode(&self) -> Result<Vec<u8>, RuntimeError> {
        if self.version != Self::VERSION || self.machines.len() > MAX_SNAPSHOT_MACHINES {
            return Err(RuntimeError::InvalidSnapshot);
        }
        let bytes = serde_json::to_vec(self).map_err(|_| RuntimeError::InvalidSnapshot)?;
        if bytes.len() > MAX_SNAPSHOT_BYTES {
            return Err(RuntimeError::SnapshotTooLarge);
        }
        Ok(bytes)
    }

    /// Decodes a snapshot for exactly one deployment; unknown fields are refused.
    pub fn decode(bytes: &[u8], host: &str, port: Option<u16>) -> Result<Self, RuntimeError> {
        if bytes.len() > MAX_SNAPSHOT_BYTES {
            return Err(RuntimeError::SnapshotTooLarge);
        }
        let value: serde_json::Value =
            serde_json::from_slice(bytes).map_err(|_| RuntimeError::InvalidSnapshot)?;
        let object = value.as_object().ok_or(RuntimeError::InvalidSnapshot)?;
        let allowed = ["version", "host", "port", "saved_at", "machines"];
        if object.keys().any(|key| !allowed.contains(&key.as_str()))
            || object.len() != allowed.len()
        {
            return Err(RuntimeError::InvalidSnapshot);
        }
        let snapshot: Self =
            serde_json::from_value(value).map_err(|_| RuntimeError::InvalidSnapshot)?;
        if snapshot.version != Self::VERSION
            || snapshot.host != host
            || snapshot.port != port
            || snapshot.machines.len() > MAX_SNAPSHOT_MACHINES
        {
            return Err(RuntimeError::InvalidSnapshot);
        }
        validate_host(host)?;
        Ok(snapshot)
    }

    /// Merges complete listings without allowing stale responses to overwrite fresh data.
    pub fn merge(current: Option<Self>, fresh: Self) -> Result<Self, RuntimeError> {
        if let Some(current) = current {
            if current.host != fresh.host || current.port != fresh.port {
                return Err(RuntimeError::SnapshotDeploymentMismatch);
            }
            if current.saved_at > fresh.saved_at {
                return Ok(current);
            }
        }
        Ok(fresh)
    }
}

fn validate_host(host: &str) -> Result<(), RuntimeError> {
    if host.is_empty()
        || host.len() > 253
        || host.split('.').any(|label| {
            label.is_empty()
                || label.len() > 63
                || label.starts_with('-')
                || label.ends_with('-')
                || !label
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        })
    {
        return Err(RuntimeError::InvalidSnapshot);
    }
    Ok(())
}

/// Push registration data kept in memory while a platform token is exchanged.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PushRegistration {
    pub platform: mila_model::DevicePlatform,
    pub push_key: String,
    pub key_id: String,
    pub expires_at: u64,
}
impl PushRegistration {
    pub fn new(
        platform: mila_model::DevicePlatform,
        push_key: String,
        key_id: String,
        expires_at: u64,
        now: u64,
    ) -> Result<Self, RuntimeError> {
        if !(16..=700).contains(&push_key.len())
            || !push_key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            || key_id.is_empty()
            || key_id.len() > 128
            || expires_at <= now
        {
            return Err(RuntimeError::InvalidPushRegistration);
        }
        Ok(Self {
            platform,
            push_key,
            key_id,
            expires_at,
        })
    }
}

/// Metadata for a Susan poke; ciphertext remains opaque to the core.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PokeEnvelope {
    pub deployment: String,
    pub push_key: String,
    pub delivery_id: String,
    pub collapse_id: String,
    pub kind: String,
    pub issued_at: u64,
    pub nonce: String,
    pub ciphertext: String,
}
impl PokeEnvelope {
    pub fn validate(&self, now: u64) -> Result<(), RuntimeError> {
        validate_host(&self.deployment)?;
        if self.push_key.is_empty()
            || self.push_key.len() > 700
            || !base64url(&self.push_key)
            || self.delivery_id.is_empty()
            || self.delivery_id.len() > 128
            || self.collapse_id.is_empty()
            || self.collapse_id.len() > 128
            || self.kind.is_empty()
            || self.kind.len() > 64
            || self.nonce.is_empty()
            || self.nonce.len() > 128
            || self.ciphertext.is_empty()
            || self.ciphertext.len() > 4096
            || !base64url(&self.ciphertext)
            || self.issued_at > now.saturating_add(300)
            || now.saturating_sub(self.issued_at) > 86_400
        {
            return Err(RuntimeError::InvalidPoke);
        }
        Ok(())
    }
}
fn base64url(value: &str) -> bool {
    value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

// (Variants are kept stable for FFI consumers.)

/// A transport-independent operation submitted through a single mutation identity.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MutationRequest {
    pub request_id: RequestId,
    pub command: String,
}

/// I/O supplied by each platform adapter. The core controls retries and polling.
pub trait SessionBackend {
    type Error;
    fn submit(&mut self, request: &MutationRequest) -> Result<Reply, Self::Error>;
    fn poll(&mut self, request_id: &RequestId) -> Result<Reply, Self::Error>;
}

/// Owns one mutation tracker and prevents accidental duplicate submissions.
#[derive(Clone, Debug, PartialEq)]
pub struct SessionRuntime {
    tracker: MutationTracker,
    command: String,
    submitted: bool,
}
impl SessionRuntime {
    pub fn new(request_id: RequestId, command: String) -> Result<Self, RuntimeError> {
        if command.is_empty() || command.len() > mila_protocol::MAX_COMMAND_BYTES {
            return Err(RuntimeError::InvalidCommand);
        }
        Ok(Self {
            tracker: MutationTracker::submitted(request_id),
            command,
            submitted: false,
        })
    }
    pub fn tracker(&self) -> &MutationTracker {
        &self.tracker
    }
    pub fn submit<B: SessionBackend>(&mut self, backend: &mut B) -> Result<(), RuntimeError> {
        if self.submitted {
            return Err(RuntimeError::AlreadySubmitted);
        }
        self.submitted = true;
        let request = MutationRequest {
            request_id: self.tracker.request_id.clone(),
            command: self.command.clone(),
        };
        let reply = backend
            .submit(&request)
            .map_err(|_| RuntimeError::Backend)?;
        self.tracker.observe(reply)
    }
    pub fn poll<B: SessionBackend>(&mut self, backend: &mut B) -> Result<NextAction, RuntimeError> {
        if !self.submitted {
            return Err(RuntimeError::NotSubmitted);
        }
        if self.tracker.next_action() == NextAction::Done {
            return Ok(NextAction::Done);
        }
        self.tracker.polled()?;
        let reply = backend
            .poll(&self.tracker.request_id)
            .map_err(|_| RuntimeError::Backend)?;
        self.tracker.observe(reply)?;
        Ok(self.tracker.next_action())
    }
}

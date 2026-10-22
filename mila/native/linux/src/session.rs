//! Linux enrollment and authenticated-session ownership.
//!
//! This module is deliberately independent of GTK.  The UI receives only the
//! state and bounded listing projection; the Rust FFI handle remains the sole
//! authority for an authenticated deployment connection.

use crate::adapter::RuntimeError;
use mila_ffi::{MilaFfiStatus, MilaRouteOutput};

const MAX_TRUST_BYTES: usize = 8192;
const MAX_LISTING_BYTES: usize = 1 << 20;

/// A signer supplied by the Linux host. Private key bytes never enter this API.
pub trait DeviceSigner: Send + Sync {
    fn public_key(&self) -> &str;
    fn sign(&self, message: &[u8]) -> Result<[u8; 64], RuntimeError>;
}

unsafe extern "C" fn sign_trampoline<S: DeviceSigner>(
    context: usize,
    message: *const u8,
    length: usize,
    signature: *mut u8,
) -> i32 {
    if context == 0 || message.is_null() || signature.is_null() || length == 0 || length > 65_536 {
        return -1;
    }
    // SAFETY: `mila_session_connect` invokes this callback synchronously and
    // promises that the context and message remain valid for the call.
    let signer = &*(context as *const S);
    let message = std::slice::from_raw_parts(message, length);
    let Ok(value) = signer.sign(message) else {
        return -1;
    };
    std::slice::from_raw_parts_mut(signature, 64).copy_from_slice(&value);
    0
}

/// Material needed to open one certificate-authenticated session.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionConnectConfig {
    pub trust_document: Vec<u8>,
    pub host: String,
    pub port: u16,
    pub timeout_ms: u32,
}

impl SessionConnectConfig {
    pub fn validate(&self) -> Result<(), RuntimeError> {
        if self.trust_document.is_empty()
            || self.trust_document.len() > MAX_TRUST_BYTES
            || self.host.is_empty()
            || self.host.len() > 180
            || self.host.bytes().any(|b| b.is_ascii_control() || b == b' ')
            || self.port == 0
            || !(1..=120_000).contains(&self.timeout_ms)
        {
            return Err(RuntimeError::InvalidInput);
        }
        Ok(())
    }
}

/// Stable errors for the GTK host; no remote response or credential is exposed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionError {
    InvalidInput,
    Transport,
    Busy,
    StaleHandle,
    Unavailable,
}

impl From<mila_ffi::session::SessionStatus> for SessionError {
    fn from(value: mila_ffi::session::SessionStatus) -> Self {
        use mila_ffi::session::SessionStatus as S;
        match value {
            S::Invalid => Self::InvalidInput,
            S::InvalidHandle => Self::StaleHandle,
            S::Busy => Self::Busy,
            S::NotLoaded => Self::Unavailable,
            S::Transport | S::Internal => Self::Transport,
            S::Ok | S::SmallBuffer => Self::Unavailable,
        }
    }
}

/// One owned FFI session. Closing removes the remote authority exactly once.
pub struct LiveSession {
    handle: Option<u64>,
}

impl LiveSession {
    /// Opens a Rust session. The signer reference is used only during the
    /// synchronous FFI call and is never retained by the C ABI.
    pub fn connect<S: DeviceSigner>(
        config: &SessionConnectConfig,
        signer: &S,
    ) -> Result<Self, SessionError> {
        config.validate().map_err(|_| SessionError::InvalidInput)?;
        let public_key = signer.public_key();
        if public_key.is_empty() || public_key.len() > 1024 {
            return Err(SessionError::InvalidInput);
        }
        let mut handle = 0_u64;
        let status = unsafe {
            mila_ffi::session::mila_session_connect(
                config.trust_document.as_ptr(),
                config.trust_document.len(),
                config.host.as_bytes().as_ptr(),
                config.host.len(),
                public_key.as_bytes().as_ptr(),
                public_key.len(),
                config.port,
                config.timeout_ms,
                Some(sign_trampoline::<S>),
                signer as *const S as usize,
                &mut handle,
            )
        };
        if status != mila_ffi::session::SessionStatus::Ok || handle == 0 {
            return Err(status.into());
        }
        Ok(Self {
            handle: Some(handle),
        })
    }

    pub fn refresh(&mut self) -> Result<Vec<u8>, SessionError> {
        let handle = self.handle()?;
        let status = mila_ffi::session::mila_session_read_machines(handle, 0);
        if status != mila_ffi::session::SessionStatus::Ok {
            return Err(status.into());
        }
        self.listing()
    }

    pub fn listing(&self) -> Result<Vec<u8>, SessionError> {
        let handle = self.handle()?;
        copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_listing(handle, out, capacity, written)
        })
    }

    pub fn read_more(&mut self) -> Result<Vec<u8>, SessionError> {
        let handle = self.handle()?;
        let status = mila_ffi::session::mila_session_read_machines(handle, 1);
        if status != mila_ffi::session::SessionStatus::Ok {
            return Err(status.into());
        }
        self.listing()
    }

    pub fn close(&mut self) -> Result<(), SessionError> {
        let Some(handle) = self.handle.take() else {
            return Ok(());
        };
        let status = mila_ffi::session::mila_session_close(handle);
        if status == mila_ffi::session::SessionStatus::Ok {
            Ok(())
        } else {
            Err(status.into())
        }
    }

    pub fn is_open(&self) -> bool {
        self.handle.is_some()
    }

    fn handle(&self) -> Result<u64, SessionError> {
        self.handle.ok_or(SessionError::StaleHandle)
    }
}

impl Drop for LiveSession {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

fn copy_output(
    mut call: impl FnMut(*mut u8, usize, *mut usize) -> mila_ffi::session::SessionStatus,
) -> Result<Vec<u8>, SessionError> {
    let mut size = 0_usize;
    let status = call(std::ptr::null_mut(), 0, &mut size);
    if status != mila_ffi::session::SessionStatus::SmallBuffer
        || size == 0
        || size > MAX_LISTING_BYTES
    {
        return Err(status.into());
    }
    let mut bytes = vec![0_u8; size];
    let status = call(bytes.as_mut_ptr(), bytes.len(), &mut size);
    if status != mila_ffi::session::SessionStatus::Ok || size > bytes.len() {
        return Err(status.into());
    }
    bytes.truncate(size);
    Ok(bytes)
}

/// The one session authority presented to the rest of the native UI.
#[derive(Default)]
pub struct SessionBinding {
    session: Option<LiveSession>,
}

impl SessionBinding {
    pub fn bind(&mut self, session: LiveSession) {
        self.clear();
        self.session = Some(session);
    }
    pub fn clear(&mut self) {
        if let Some(mut session) = self.session.take() {
            let _ = session.close();
        }
    }
    pub fn session(&self) -> Option<&LiveSession> {
        self.session.as_ref()
    }
    pub fn session_mut(&mut self) -> Option<&mut LiveSession> {
        self.session.as_mut()
    }
    pub fn is_authenticated(&self) -> bool {
        self.session.as_ref().is_some_and(LiveSession::is_open)
    }
}

/// Storage used by enrollment. Implementations must use owner-only, atomic files.
pub trait TrustStore {
    fn read(&self, host: &str) -> Result<Option<Vec<u8>>, RuntimeError>;
    fn write(&self, host: &str, document: &[u8]) -> Result<(), RuntimeError>;
}

/// Fetches `/bin/ssh-trust.json` over HTTPS with redirects refused.
pub trait TrustFetcher {
    fn fetch(&self, host: &str) -> Result<Vec<u8>, RuntimeError>;
}

/// Rust-owned trust enrollment. Only canonical bytes selected by the FFI are persisted.
pub struct TrustEnrollment<S, F> {
    pub store: S,
    pub fetcher: F,
}

impl<S: TrustStore, F: TrustFetcher> TrustEnrollment<S, F> {
    /// @cc [owner:ghuntley,label:security] linux-trust-enrollment-order
    /// Enrollment MUST reconcile fetched and pinned documents in Rust and persist
    /// only the canonical result. A failed fetch may use a current pin; malformed
    /// or conflicting fetched bytes MUST fail closed.
    pub fn resolve(&self, host: &str, now: u64) -> Result<Vec<u8>, RuntimeError> {
        let pinned = self.store.read(host)?;
        let fetched = self.fetcher.fetch(host).ok();
        let mut output = vec![0_u8; MAX_TRUST_BYTES];
        let mut written = 0_usize;
        let origin = std::ffi::CString::new(host).map_err(|_| RuntimeError::InvalidInput)?;
        let status = unsafe {
            mila_ffi::mila_trust_document_reconcile(
                pinned.as_deref().map_or(std::ptr::null(), <[u8]>::as_ptr),
                pinned.as_ref().map_or(0, Vec::len),
                fetched.as_deref().map_or(std::ptr::null(), <[u8]>::as_ptr),
                fetched.as_ref().map_or(0, Vec::len),
                origin.as_ptr(),
                now,
                MilaRouteOutput {
                    bytes: output.as_mut_ptr(),
                    capacity: output.len(),
                    written: &mut written,
                },
            )
        };
        if status != MilaFfiStatus::Ok || written == 0 || written > output.len() {
            return Err(RuntimeError::InvalidInput);
        }
        output.truncate(written);
        if pinned.as_deref() != Some(output.as_slice()) {
            self.store.write(host, &output)?;
        }
        Ok(output)
    }
}

/// Browser approval state retained without persisting URLs, tokens or fingerprints.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum ApprovalState {
    #[default]
    NotRequired,
    Pending,
    Approved,
    Rejected,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SignInPhase {
    SignedOut,
    Connecting,
    AwaitingApproval,
    SignedIn,
    Disconnected,
    Expired,
    Failed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SignInFailure {
    HostUntrusted,
    Refused,
    Protocol,
    Unreachable,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalInfo {
    pub url: String,
    pub fingerprint: String,
    pub issued_at: u64,
}

impl ApprovalInfo {
    pub fn validate(url: &str, fingerprint: &str, issued_at: u64) -> Result<Self, RuntimeError> {
        let authority = url
            .strip_prefix("https://")
            .and_then(|rest| rest.split(['/', '?']).next());
        let valid_url = url.len() <= 2048
            && authority.is_some_and(|host| {
                !host.is_empty()
                    && host != ":443"
                    && !host.starts_with(':')
                    && host
                        .chars()
                        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-'))
            })
            && !url[8..].contains(['@', '#', ' ', '\t', '\n', '\r']);
        if !valid_url || fingerprint.is_empty() || fingerprint.len() > 256 {
            return Err(RuntimeError::InvalidInput);
        }
        Ok(Self {
            url: url.to_owned(),
            fingerprint: fingerprint.to_owned(),
            issued_at,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SignInFlow {
    pub phase: SignInPhase,
    pub generation: u64,
    pub approval: Option<ApprovalInfo>,
    pub account: Option<String>,
    pub failure: Option<SignInFailure>,
}

impl Default for SignInFlow {
    fn default() -> Self {
        Self {
            phase: SignInPhase::SignedOut,
            generation: 0,
            approval: None,
            account: None,
            failure: None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WhoamiOutcome {
    Authenticated { account: String },
    Approval { url: String, fingerprint: String },
    Refused,
    Unavailable,
    Protocol,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SignInEvent {
    Start,
    Connected(u64),
    HostRejected(u64),
    Whoami {
        generation: u64,
        outcome: WhoamiOutcome,
        at: u64,
    },
    Unreachable(u64),
    Disconnected(u64),
    SignOut,
    Tick(u64),
}

impl SignInFlow {
    pub fn apply(mut self, event: SignInEvent) -> Self {
        match event {
            SignInEvent::Start
                if !matches!(self.phase, SignInPhase::SignedIn | SignInPhase::Connecting) =>
            {
                self.generation = self.generation.saturating_add(1);
                self.phase = SignInPhase::Connecting;
                self.approval = None;
                self.failure = None;
            }
            SignInEvent::Connected(g) if g == self.generation => {}
            SignInEvent::HostRejected(g) if g == self.generation => {
                self.fail(SignInFailure::HostUntrusted)
            }
            SignInEvent::Unreachable(g)
                if g == self.generation && self.phase == SignInPhase::Connecting =>
            {
                self.fail(SignInFailure::Unreachable)
            }
            SignInEvent::Disconnected(g) if g == self.generation => match self.phase {
                SignInPhase::AwaitingApproval | SignInPhase::Connecting => {
                    self.phase = SignInPhase::Expired;
                    self.approval = None;
                }
                SignInPhase::SignedIn => self.phase = SignInPhase::Disconnected,
                _ => {}
            },
            SignInEvent::Whoami {
                generation,
                outcome,
                at,
            } if generation == self.generation => match outcome {
                WhoamiOutcome::Authenticated { account }
                    if matches!(
                        self.phase,
                        SignInPhase::Connecting | SignInPhase::AwaitingApproval
                    ) =>
                {
                    self.phase = SignInPhase::SignedIn;
                    self.account = Some(account);
                    self.approval = None;
                }
                WhoamiOutcome::Approval { url, fingerprint }
                    if self.phase != SignInPhase::AwaitingApproval =>
                {
                    if let Ok(info) = ApprovalInfo::validate(&url, &fingerprint, at) {
                        self.phase = SignInPhase::AwaitingApproval;
                        self.approval = Some(info);
                    }
                }
                WhoamiOutcome::Refused => self.fail(SignInFailure::Refused),
                WhoamiOutcome::Protocol => self.fail(SignInFailure::Protocol),
                _ => {}
            },
            SignInEvent::Tick(now)
                if self.phase == SignInPhase::AwaitingApproval
                    && self
                        .approval
                        .as_ref()
                        .is_some_and(|a| now.saturating_sub(a.issued_at) >= 600) =>
            {
                self.phase = SignInPhase::Expired;
                self.approval = None;
            }
            SignInEvent::SignOut => {
                self.generation = self.generation.saturating_add(1);
                self.phase = SignInPhase::SignedOut;
                self.approval = None;
                self.account = None;
                self.failure = None;
            }
            _ => {}
        }
        self
    }
    fn fail(&mut self, failure: SignInFailure) {
        self.phase = SignInPhase::Failed;
        self.failure = Some(failure);
        self.approval = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn approval_is_generation_bound_and_expires() {
        let flow = SignInFlow::default().apply(SignInEvent::Start);
        let generation = flow.generation;
        let flow = flow.apply(SignInEvent::Whoami {
            generation: generation + 1,
            outcome: WhoamiOutcome::Approval {
                url: "https://example.test/approve".into(),
                fingerprint: "SHA256:test".into(),
            },
            at: 1,
        });
        assert_eq!(flow.phase, SignInPhase::Connecting);
        let flow = flow.apply(SignInEvent::Whoami {
            generation,
            outcome: WhoamiOutcome::Approval {
                url: "https://example.test/approve".into(),
                fingerprint: "SHA256:test".into(),
            },
            at: 1,
        });
        assert_eq!(flow.phase, SignInPhase::AwaitingApproval);
        assert_eq!(
            flow.apply(SignInEvent::Tick(601)).phase,
            SignInPhase::Expired
        );
    }
    #[test]
    fn reconnect_after_disconnect_starts_fresh_generation() {
        let flow = SignInFlow::default().apply(SignInEvent::Start);
        let generation = flow.generation;
        let flow = flow
            .apply(SignInEvent::Whoami {
                generation,
                outcome: WhoamiOutcome::Authenticated {
                    account: "operator@example.test".into(),
                },
                at: 1,
            })
            .apply(SignInEvent::Disconnected(generation));
        assert_eq!(flow.phase, SignInPhase::Disconnected);
        let flow = flow.apply(SignInEvent::Start);
        assert_eq!(
            (flow.phase, flow.generation),
            (SignInPhase::Connecting, generation + 1)
        );
    }
    #[test]
    fn approval_url_validation_rejects_userinfo_and_non_https() {
        assert!(ApprovalInfo::validate("http://example.test/a", "fp", 0).is_err());
        assert!(ApprovalInfo::validate("https://user@example.test/a", "fp", 0).is_err());
        assert!(ApprovalInfo::validate("https://?approval", "fp", 0).is_err());
        assert!(ApprovalInfo::validate("https://:443/a", "fp", 0).is_err());
        assert!(ApprovalInfo::validate("https://example.test/a", "fp", 0).is_ok());
    }
}

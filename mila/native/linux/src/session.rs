//! Linux enrollment and authenticated-session ownership.
//!
//! This module is deliberately independent of GTK.  The UI receives only the
//! state and bounded listing projection; the Rust FFI handle remains the sole
//! authority for an authenticated deployment connection.

use crate::adapter::RuntimeError;
use mila_ffi::{MilaFfiStatus, MilaRouteOutput};
use p256::ecdsa::{signature::Signer, Signature, SigningKey};

const MAX_TRUST_BYTES: usize = 8192;
const MAX_LISTING_BYTES: usize = 1 << 20;

/// A signer supplied by the Linux host. Private key bytes never enter this API.
pub trait DeviceSigner: Send + Sync {
    fn public_key(&self) -> &str;
    fn sign(&self, message: &[u8]) -> Result<[u8; 64], RuntimeError>;
}

/// A Linux software signer backed by an owner-only raw P-256 key file.
/// Hardware-backed desktop signers can implement [`DeviceSigner`] directly;
/// this adapter exists for the Linux development and release bundle where the
/// key is provisioned outside the GTK process.
/// @cc [owner:ghuntley,label=security] linux-file-signer-custody
/// A file-backed Linux signer MUST reject symlinks and any group/world
/// permission bits before reading key material, and MUST expose only signatures
/// and the configured public key to the session boundary.
pub struct FileDeviceSigner {
    key: SigningKey,
    public_key: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SignerError {
    Unavailable,
    InsecurePermissions,
    InvalidKey,
}

impl FileDeviceSigner {
    /// Loads exactly 32 raw key bytes and refuses symlinks or group/world access.
    pub fn load(path: &std::path::Path, public_key: String) -> Result<Self, SignerError> {
        use std::{fs, os::unix::fs::PermissionsExt};
        let metadata = fs::symlink_metadata(path).map_err(|_| SignerError::Unavailable)?;
        if !metadata.file_type().is_file() || metadata.permissions().mode() & 0o077 != 0 {
            return Err(SignerError::InsecurePermissions);
        }
        if public_key.is_empty() || public_key.len() > 1024 {
            return Err(SignerError::InvalidKey);
        }
        let bytes = fs::read(path).map_err(|_| SignerError::Unavailable)?;
        let key = SigningKey::from_slice(&bytes).map_err(|_| SignerError::InvalidKey)?;
        Ok(Self { key, public_key })
    }
}

impl DeviceSigner for FileDeviceSigner {
    fn public_key(&self) -> &str {
        &self.public_key
    }

    fn sign(&self, message: &[u8]) -> Result<[u8; 64], RuntimeError> {
        let signature: Signature = self.key.sign(message);
        let mut output = [0_u8; 64];
        output.copy_from_slice(&signature.to_bytes());
        Ok(output)
    }
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
        if self.trust_document.is_empty() || self.trust_document.len() > MAX_TRUST_BYTES {
            return Err(RuntimeError::InvalidInput);
        }
        validate_session_endpoint(&self.host, self.port, self.timeout_ms)?;
        Ok(())
    }
}

fn validate_session_endpoint(host: &str, port: u16, timeout_ms: u32) -> Result<(), RuntimeError> {
    if host.is_empty()
        || host.len() > 180
        || host.bytes().any(|b| b.is_ascii_control() || b == b' ')
        || port == 0
        || !(1..=120_000).contains(&timeout_ms)
    {
        return Err(RuntimeError::InvalidInput);
    }
    Ok(())
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

    /// Read a machine-bound web endpoint through the authenticated session.
    /// The response remains bounded and owned by the Rust adapter.
    pub fn web_show(&mut self, machine_id: &str) -> Result<Vec<u8>, SessionError> {
        validate_session_identifier(machine_id)?;
        let handle = self.handle()?;
        copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_web_show(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                out,
                capacity,
                written,
            )
        })
    }

    /// Change a machine web endpoint using its optimistic policy revision.
    pub fn web_set(
        &mut self,
        machine_id: &str,
        port: u16,
        public: bool,
        revision: u64,
        request_id: &str,
    ) -> Result<(), SessionError> {
        validate_session_identifier(machine_id)?;
        if port == 0
            || request_id.len() != 40
            || !request_id.starts_with("porsche-")
            || !request_id[8..].bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(SessionError::InvalidInput);
        }
        let handle = self.handle()?;
        let status = unsafe {
            mila_ffi::session::mila_session_web_set(
                handle,
                machine_id.as_bytes().as_ptr(),
                machine_id.len(),
                port,
                u8::from(public),
                revision,
                request_id.as_bytes().as_ptr(),
                request_id.len(),
            )
        };
        if status == mila_ffi::session::SessionStatus::Ok {
            Ok(())
        } else {
            Err(status.into())
        }
    }

    /// Read authenticated push notification devices. Provider registration is
    /// intentionally host-owned; this method covers list and preference CRUD.
    pub fn device_list(&mut self) -> Result<Vec<u8>, SessionError> {
        let handle = self.handle()?;
        copy_output(|out, capacity, written| unsafe {
            mila_ffi::session::mila_session_device_ls(handle, out, capacity, written)
        })
    }

    pub fn device_remove(&mut self, device_id: &str) -> Result<(), SessionError> {
        validate_session_identifier(device_id)?;
        let handle = self.handle()?;
        let status = unsafe {
            mila_ffi::session::mila_session_device_rm(
                handle,
                device_id.as_bytes().as_ptr(),
                device_id.len(),
            )
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
    }

    pub fn device_preference(
        &mut self,
        device_id: &str,
        enabled: bool,
    ) -> Result<(), SessionError> {
        validate_session_identifier(device_id)?;
        let handle = self.handle()?;
        let status = unsafe {
            mila_ffi::session::mila_session_device_prefs(
                handle,
                device_id.as_bytes().as_ptr(),
                device_id.len(),
                u8::from(enabled),
            )
        };
        (status == mila_ffi::session::SessionStatus::Ok)
            .then_some(())
            .ok_or_else(|| status.into())
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

fn validate_session_identifier(value: &str) -> Result<(), SessionError> {
    if value.is_empty()
        || value.len() > 128
        || value
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace() || byte == 0)
    {
        return Err(SessionError::InvalidInput);
    }
    Ok(())
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
    /// or conflicting fetched bytes MUST fail closed. Only an unavailable HTTPS
    /// transport may fall back to a current pin; fetch validation errors MUST
    /// be returned.
    pub fn resolve(&self, host: &str, now: u64) -> Result<Vec<u8>, RuntimeError> {
        let pinned = self.store.read(host)?;
        let fetched = match self.fetcher.fetch(host) {
            Ok(document) => Some(document),
            Err(RuntimeError::Unavailable) => None,
            Err(RuntimeError::InvalidInput) => return Err(RuntimeError::InvalidInput),
        };
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

/// Rust-owned sign-in planning and connection orchestration for the Linux host.
/// The host supplies only the signer and I/O traits; trust selection and the
/// session configuration remain inside this module.
pub struct SignInCoordinator<S, T, F> {
    signer: S,
    enrollment: TrustEnrollment<T, F>,
}

impl<S: DeviceSigner, T: TrustStore, F: TrustFetcher> SignInCoordinator<S, T, F> {
    pub fn new(signer: S, store: T, fetcher: F) -> Self {
        Self {
            signer,
            enrollment: TrustEnrollment { store, fetcher },
        }
    }

    /// @cc [owner:ghuntley,label:security] linux-signin-coordinator-order
    /// Sign-in MUST validate the endpoint before invoking host storage or HTTPS,
    /// reconcile trust entirely in Rust, and pass only the selected trust bytes
    /// to session connection. A failed plan MUST NOT invoke the device signer.
    pub fn prepare_connect(
        &self,
        host: &str,
        port: u16,
        timeout_ms: u32,
        now: u64,
    ) -> Result<SessionConnectConfig, RuntimeError> {
        validate_session_endpoint(host, port, timeout_ms)?;
        let trust_document = self.enrollment.resolve(host, now)?;
        let config = SessionConnectConfig {
            trust_document,
            host: host.to_owned(),
            port,
            timeout_ms,
        };
        config.validate()?;
        Ok(config)
    }

    pub fn connect(
        &self,
        host: &str,
        port: u16,
        timeout_ms: u32,
        now: u64,
    ) -> Result<LiveSession, SessionError> {
        let config =
            self.prepare_connect(host, port, timeout_ms, now)
                .map_err(|error| match error {
                    RuntimeError::InvalidInput => SessionError::InvalidInput,
                    RuntimeError::Unavailable => SessionError::Transport,
                })?;
        LiveSession::connect(&config, &self.signer)
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
    use std::cell::RefCell;
    use std::fs;
    use std::rc::Rc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct MemoryStore {
        pinned: Option<Vec<u8>>,
        reads: Rc<RefCell<usize>>,
        writes: Rc<RefCell<Vec<Vec<u8>>>>,
    }

    impl TrustStore for MemoryStore {
        fn read(&self, _host: &str) -> Result<Option<Vec<u8>>, RuntimeError> {
            *self.reads.borrow_mut() += 1;
            Ok(self.pinned.clone())
        }

        fn write(&self, _host: &str, document: &[u8]) -> Result<(), RuntimeError> {
            self.writes.borrow_mut().push(document.to_vec());
            Ok(())
        }
    }

    struct StaticFetcher {
        response: Result<Vec<u8>, RuntimeError>,
        calls: Rc<RefCell<usize>>,
    }

    impl TrustFetcher for StaticFetcher {
        fn fetch(&self, _host: &str) -> Result<Vec<u8>, RuntimeError> {
            *self.calls.borrow_mut() += 1;
            self.response.clone()
        }
    }

    struct CountingSigner {
        calls: Arc<AtomicUsize>,
    }

    #[test]
    fn file_signer_requires_owner_only_key_and_verifies_signature() {
        use p256::ecdsa::signature::Verifier;
        use std::os::unix::fs::PermissionsExt;

        let path = std::env::temp_dir().join(format!(
            "mila-signer-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ));
        fs::write(&path, [7_u8; 32]).expect("key");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("permissions");
        let signer = FileDeviceSigner::load(&path, "ssh-test-public-key".to_owned()).unwrap();
        let message = b"certificate challenge";
        let signature = signer.sign(message).unwrap();
        let parsed = Signature::from_slice(&signature).unwrap();
        signer.key.verifying_key().verify(message, &parsed).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).expect("permissions");
        assert!(matches!(
            FileDeviceSigner::load(&path, "ssh-test-public-key".to_owned()),
            Err(SignerError::InsecurePermissions)
        ));
        fs::remove_file(path).expect("cleanup");
    }

    impl DeviceSigner for CountingSigner {
        fn public_key(&self) -> &str {
            "ssh-test-public-key"
        }

        fn sign(&self, _message: &[u8]) -> Result<[u8; 64], RuntimeError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Ok([0; 64])
        }
    }

    fn ca(index: usize) -> String {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../rust/mila-transport/tests/fixtures/ssh_host_certificates.json"
        ))
        .expect("certificate fixture");
        fixture["certificates"][index]["ca"]
            .as_str()
            .expect("certificate CA")
            .to_owned()
    }

    fn trust(ca: &str, retirement: u64) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "ca": ca,
            "management_host": "overalls.example",
            "zone": "apps.overalls.example",
            "retirement": retirement,
        }))
        .expect("trust document")
    }

    fn coordinator(
        pinned: Option<Vec<u8>>,
        response: Result<Vec<u8>, RuntimeError>,
    ) -> (
        SignInCoordinator<CountingSigner, MemoryStore, StaticFetcher>,
        Rc<RefCell<usize>>,
        Rc<RefCell<Vec<Vec<u8>>>>,
        Arc<AtomicUsize>,
    ) {
        let reads = Rc::new(RefCell::new(0));
        let writes = Rc::new(RefCell::new(Vec::new()));
        let calls = Rc::new(RefCell::new(0));
        let signer_calls = Arc::new(AtomicUsize::new(0));
        (
            SignInCoordinator::new(
                CountingSigner {
                    calls: signer_calls.clone(),
                },
                MemoryStore {
                    pinned,
                    reads,
                    writes: writes.clone(),
                },
                StaticFetcher {
                    response,
                    calls: calls.clone(),
                },
            ),
            calls,
            writes,
            signer_calls,
        )
    }

    #[test]
    fn coordinator_reconciles_fetched_trust_and_persists_canonical_bytes() {
        let pinned = trust(&ca(0), 2_000);
        let fetched = trust(&ca(0), 3_000);
        let (coordinator, fetch_calls, writes, _) = coordinator(Some(pinned), Ok(fetched));
        let config = coordinator
            .prepare_connect("overalls.example", 443, 30_000, 1_000)
            .expect("trust should reconcile");
        let selected: serde_json::Value =
            serde_json::from_slice(&config.trust_document).expect("canonical trust");
        assert_eq!(selected["retirement"], 3_000);
        assert_eq!(*fetch_calls.borrow(), 1);
        assert_eq!(writes.borrow().len(), 1);
        assert_eq!(writes.borrow()[0], config.trust_document);
    }

    #[test]
    fn coordinator_uses_a_current_pin_when_fetch_is_unavailable() {
        let pinned = trust(&ca(0), 2_000);
        let (coordinator, fetch_calls, writes, _) =
            coordinator(Some(pinned.clone()), Err(RuntimeError::Unavailable));
        let config = coordinator
            .prepare_connect("overalls.example", 443, 30_000, 1_000)
            .expect("current pin should be usable");
        let selected: serde_json::Value =
            serde_json::from_slice(&config.trust_document).expect("canonical trust");
        assert_eq!(selected["retirement"], 2_000);
        assert_eq!(
            selected["ca"],
            serde_json::from_slice::<serde_json::Value>(&pinned).unwrap()["ca"]
        );
        assert_eq!(*fetch_calls.borrow(), 1);
        assert_eq!(writes.borrow().len(), 1);
        assert_eq!(writes.borrow()[0], config.trust_document);
    }

    #[test]
    fn coordinator_refuses_malformed_or_conflicting_fetched_trust() {
        let malformed = coordinator(None, Ok(br#"{"version":1,"ca":"bad"}"#.to_vec())).0;
        assert_eq!(
            malformed
                .prepare_connect("overalls.example", 443, 30_000, 1_000)
                .unwrap_err(),
            RuntimeError::InvalidInput
        );

        let conflicting = coordinator(Some(trust(&ca(0), 2_000)), Ok(trust(&ca(5), 3_000))).0;
        assert_eq!(
            conflicting
                .prepare_connect("overalls.example", 443, 30_000, 1_000)
                .unwrap_err(),
            RuntimeError::InvalidInput
        );

        let malformed_fetch =
            coordinator(Some(trust(&ca(0), 2_000)), Err(RuntimeError::InvalidInput)).0;
        assert_eq!(
            malformed_fetch
                .prepare_connect("overalls.example", 443, 30_000, 1_000)
                .unwrap_err(),
            RuntimeError::InvalidInput
        );
    }

    #[test]
    fn invalid_endpoint_is_rejected_before_storage_fetch_or_signer() {
        let (coordinator, fetch_calls, writes, signer_calls) =
            coordinator(None, Err(RuntimeError::Unavailable));
        assert!(matches!(
            coordinator.connect("bad host", 443, 30_000, 1_000),
            Err(SessionError::InvalidInput)
        ));
        assert_eq!(*fetch_calls.borrow(), 0);
        assert!(writes.borrow().is_empty());
        assert_eq!(signer_calls.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn web_controls_require_an_authenticated_handle_and_bounded_request() {
        let mut session = LiveSession { handle: None };
        assert_eq!(
            session.web_show("bad machine"),
            Err(SessionError::InvalidInput)
        );
        assert_eq!(
            session.web_set(
                "01234567-89ab-cdef-0123-456789abcdef",
                8080,
                true,
                7,
                "request-without-porsche-id"
            ),
            Err(SessionError::InvalidInput)
        );
        assert_eq!(
            session.web_set(
                "01234567-89ab-cdef-0123-456789abcdef",
                8080,
                true,
                7,
                "porsche-0123456789abcdef0123456789abcdef"
            ),
            Err(SessionError::StaleHandle)
        );
    }

    #[test]
    fn notification_device_controls_require_authenticated_session() {
        let mut session = LiveSession { handle: None };
        assert_eq!(session.device_list(), Err(SessionError::StaleHandle));
        assert_eq!(
            session.device_remove("bad device"),
            Err(SessionError::InvalidInput)
        );
        assert_eq!(
            session.device_preference("device-id", false),
            Err(SessionError::StaleHandle)
        );
    }

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

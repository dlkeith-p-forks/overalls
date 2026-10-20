//! Narrow C ABI for the Flutter platform bridge.
//!
//! The first migration slice exposes validation only. Ownership of all strings remains
//! with the caller; no secret or private key crosses this boundary.

use mila_model::MilaRoute;
use mila_runtime::MachineSnapshot;
use mila_runtime::{PokeEnvelope, PushEnvironment, PushProvider, PushRegistrationRequest};
use mila_transport::{decode_watch_line, TerminalAttachRequest, WatchEvent};
use std::ffi::{c_char, CStr};

/// FFI status values. Zero means success; negative values are stable failures.
#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MilaFfiStatus {
    Ok = 0,
    NullInput = -1,
    InvalidRoute = -2,
    OutputTooSmall = -3,
    InvalidRequest = -4,
}

/// Non-sensitive metadata extracted from a validated offline machine snapshot.
/// The machine records themselves remain in the native/runtime layer.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MilaSnapshotSummary {
    pub machine_count: u32,
    pub saved_at: u64,
}

/// Validates a bounded snapshot and returns only its count and timestamp.
/// `host` and `port` identify the deployment the native client is currently
/// connected to; snapshots for another deployment are rejected.
///
/// # Safety
/// `bytes` must reference `length` readable bytes and `host` a NUL-terminated
/// UTF-8 string. `out_summary` must point to writable summary storage.
#[no_mangle]
pub unsafe extern "C" fn mila_snapshot_validate(
    bytes: *const u8,
    length: usize,
    host: *const c_char,
    port: u16,
    has_port: u8,
    out_summary: *mut MilaSnapshotSummary,
) -> MilaFfiStatus {
    if bytes.is_null() || host.is_null() || out_summary.is_null() {
        return MilaFfiStatus::NullInput;
    }
    if has_port > 1 {
        return MilaFfiStatus::InvalidRequest;
    }
    let host = match CStr::from_ptr(host).to_str() {
        Ok(value) => value,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let input = std::slice::from_raw_parts(bytes, length);
    let snapshot = match MachineSnapshot::decode(input, host, (has_port == 1).then_some(port)) {
        Ok(value) => value,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    *out_summary = MilaSnapshotSummary {
        machine_count: snapshot.machines.len() as u32,
        saved_at: snapshot.saved_at,
    };
    MilaFfiStatus::Ok
}

/// Validates a trust document fetched for `origin_host`. The document is
/// parsed and checked entirely in Rust; no certificate or token is returned.
///
/// # Safety
/// `document` must point to `length` readable bytes and `origin_host` must be
/// a valid NUL-terminated UTF-8 string for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn mila_trust_document_validate(
    document: *const u8,
    length: usize,
    origin_host: *const c_char,
    now: u64,
) -> MilaFfiStatus {
    if document.is_null() || origin_host.is_null() {
        return MilaFfiStatus::NullInput;
    }
    // SAFETY: callers provide a readable byte buffer of `length` bytes.
    let bytes = std::slice::from_raw_parts(document, length);
    // SAFETY: caller provides a NUL-terminated host string.
    let host = match CStr::from_ptr(origin_host).to_str() {
        Ok(host) => host,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    mila_transport::decode_trust_document(bytes, host, now)
        .map(|_| MilaFfiStatus::Ok)
        .unwrap_or(MilaFfiStatus::InvalidRequest)
}

/// Validates a push registration request without carrying a platform secret
/// across the ABI. `provider`: 0=APNs, 1=FCM, 2=WNS; `environment`: 0=dev,
/// 1=production. WNS requires a channel endpoint; other providers reject one.
///
/// # Safety
/// `token`, `app_id`, and `deployment` must be valid NUL-terminated UTF-8
/// strings. If supplied, `endpoint` must meet the same requirements.
#[no_mangle]
pub unsafe extern "C" fn mila_push_registration_validate(
    provider: u8,
    environment: u8,
    token: *const c_char,
    app_id: *const c_char,
    deployment: *const c_char,
    endpoint: *const c_char,
) -> MilaFfiStatus {
    if token.is_null() || app_id.is_null() || deployment.is_null() {
        return MilaFfiStatus::NullInput;
    }
    let token = match CStr::from_ptr(token).to_str() {
        Ok(value) => value,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let deployment = match CStr::from_ptr(deployment).to_str() {
        Ok(value) => value,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let app_id = match CStr::from_ptr(app_id).to_str() {
        Ok(value) => value,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let endpoint = if endpoint.is_null() {
        None
    } else {
        match CStr::from_ptr(endpoint).to_str() {
            Ok(value) => Some(value),
            Err(_) => return MilaFfiStatus::InvalidRequest,
        }
    };
    let provider = match provider {
        0 => PushProvider::Apns,
        1 => PushProvider::Fcm,
        2 => PushProvider::Wns,
        _ => return MilaFfiStatus::InvalidRequest,
    };
    let environment = match environment {
        0 => PushEnvironment::Development,
        1 => PushEnvironment::Production,
        _ => return MilaFfiStatus::InvalidRequest,
    };
    PushRegistrationRequest::new(
        provider,
        token.to_owned(),
        app_id.to_owned(),
        environment,
        deployment.to_owned(),
        endpoint.map(str::to_owned),
    )
    .map(|_| MilaFfiStatus::Ok)
    .unwrap_or(MilaFfiStatus::InvalidRequest)
}

/// Validates a Susan push poke envelope without exposing its ciphertext to a UI.
/// The deployment is checked by the Rust runtime and the caller receives only
/// the stable status code.
///
/// # Safety
/// `envelope` must point to `length` readable UTF-8 JSON bytes.
#[no_mangle]
pub unsafe extern "C" fn mila_push_poke_validate(
    envelope: *const u8,
    length: usize,
    now: u64,
) -> MilaFfiStatus {
    if envelope.is_null() {
        return MilaFfiStatus::NullInput;
    }
    // SAFETY: callers provide a readable byte buffer of `length` bytes.
    let bytes = std::slice::from_raw_parts(envelope, length);
    let value = match serde_json::from_slice::<PokeEnvelope>(bytes) {
        Ok(value) => value,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    value
        .validate(now)
        .map_or(MilaFfiStatus::InvalidRequest, |_| MilaFfiStatus::Ok)
}

/// Checks a bounded watch subscription filter count. UUID values themselves
/// remain in the native/runtime layer and never cross this ABI.
#[no_mangle]
pub extern "C" fn mila_watch_validate_filters(
    machine_count: u16,
    thread_count: u16,
) -> MilaFfiStatus {
    if (machine_count as usize) + (thread_count as usize)
        > mila_transport::WatchRequest::MAX_FILTERS
    {
        MilaFfiStatus::InvalidRequest
    } else {
        MilaFfiStatus::Ok
    }
}

/// Stable event tags returned by [`mila_watch_event_kind`].
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MilaWatchEventKind {
    Unknown = 0,
    Watching = 1,
    Heartbeat = 2,
    MachineChanged = 3,
    TerminalSessionsChanged = 4,
    ThreadChanged = 5,
    Resync = 6,
    Session = 7,
}

/// Validates terminal dimensions before a native UI opens a PTY.
///
/// The bridge deliberately accepts only scalar values, so no platform pointer or
/// session secret crosses the ABI. `read_write` is reserved for the permission
/// boundary and is currently accepted as either 0 or 1.
#[no_mangle]
pub extern "C" fn mila_terminal_validate(columns: u16, rows: u16, read_write: u8) -> MilaFfiStatus {
    if read_write > 1 {
        return MilaFfiStatus::InvalidRequest;
    }
    let request = TerminalAttachRequest {
        machine_id: uuid::Uuid::nil(),
        session_id: uuid::Uuid::nil(),
        from: 0,
        columns,
        rows,
        read_write: read_write == 1,
    };
    request
        .validate()
        .map_or(MilaFfiStatus::InvalidRequest, |_| MilaFfiStatus::Ok)
}

/// Decodes one bounded Porsche watch line and returns only its non-sensitive tag.
///
/// # Safety
/// `line` must be either null with `length == 0`, or point to `length` readable
/// bytes. No NUL termination is required.
#[no_mangle]
pub unsafe extern "C" fn mila_watch_event_kind(
    line: *const u8,
    length: usize,
    out_kind: *mut MilaWatchEventKind,
) -> MilaFfiStatus {
    if line.is_null() || out_kind.is_null() {
        return MilaFfiStatus::NullInput;
    }
    // SAFETY: caller guarantees a readable byte slice of the supplied length.
    let bytes = std::slice::from_raw_parts(line, length);
    let event = match decode_watch_line(bytes) {
        Ok(event) => event,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let kind = match event {
        WatchEvent::Unknown => MilaWatchEventKind::Unknown,
        WatchEvent::Watching { .. } => MilaWatchEventKind::Watching,
        WatchEvent::Heartbeat => MilaWatchEventKind::Heartbeat,
        WatchEvent::MachineChanged(_) => MilaWatchEventKind::MachineChanged,
        WatchEvent::TerminalSessionsChanged(_) => MilaWatchEventKind::TerminalSessionsChanged,
        WatchEvent::ThreadChanged(_) => MilaWatchEventKind::ThreadChanged,
        WatchEvent::Resync => MilaWatchEventKind::Resync,
        WatchEvent::Session { .. } => MilaWatchEventKind::Session,
    };
    // SAFETY: caller guarantees writable storage for one event tag.
    *out_kind = kind;
    MilaFfiStatus::Ok
}

/// A fixed-size route description suitable for a caller-owned buffer.
#[repr(C)]
pub struct MilaRouteOutput {
    pub bytes: *mut u8,
    pub capacity: usize,
    pub written: *mut usize,
}

/// Returns the ABI version consumed by the platform bridge.
#[no_mangle]
pub extern "C" fn mila_ffi_version() -> u32 {
    1
}

/// ABI version represented as two C-compatible integers.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MilaFfiAbiVersion {
    pub major: u32,
    pub minor: u32,
}

/// Writes the ABI version into caller-owned storage.
///
/// # Safety
/// `out_version` must be null or point to writable storage for one `MilaFfiAbiVersion`.
#[no_mangle]
pub unsafe extern "C" fn mila_ffi_get_version(
    out_version: *mut MilaFfiAbiVersion,
) -> MilaFfiStatus {
    if out_version.is_null() {
        return MilaFfiStatus::NullInput;
    }
    // SAFETY: the caller supplied a non-null pointer to writable version storage.
    *out_version = MilaFfiAbiVersion { major: 1, minor: 0 };
    MilaFfiStatus::Ok
}

/// Parses an `overalls://` route and writes its canonical spelling to `output`.
///
/// @cc [owner:ghuntley,label:security;protocol] mila-ffi-bounded-output
/// FFI parsing MUST validate UTF-8 and the closed route grammar before writing;
/// output writes MUST be bounded by the caller-provided capacity.
///
/// # Safety
/// `input` must point to a NUL-terminated UTF-8 C string. `output.bytes` must
/// reference `capacity` writable bytes and `output.written` one writable `usize`.
#[no_mangle]
pub unsafe extern "C" fn mila_route_format(
    input: *const c_char,
    output: MilaRouteOutput,
) -> MilaFfiStatus {
    if input.is_null() || output.bytes.is_null() || output.written.is_null() {
        return MilaFfiStatus::NullInput;
    }
    let input = match CStr::from_ptr(input).to_str() {
        Ok(value) => value,
        Err(_) => return MilaFfiStatus::InvalidRoute,
    };
    let route = match MilaRoute::parse(input) {
        Ok(route) => route,
        Err(_) => return MilaFfiStatus::InvalidRoute,
    };
    let canonical = route.format();
    let bytes = canonical.as_bytes();
    if bytes.len() > output.capacity {
        return MilaFfiStatus::OutputTooSmall;
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), output.bytes, bytes.len());
    if output.capacity > bytes.len() {
        *output.bytes.add(bytes.len()) = 0;
    }
    // SAFETY: the caller supplied a valid writable `written` pointer.
    *output.written = bytes.len();
    MilaFfiStatus::Ok
}

#[cfg(test)]
mod tests {
    use super::{
        mila_ffi_get_version, mila_ffi_version, mila_terminal_validate, mila_watch_event_kind,
        mila_watch_validate_filters, MilaFfiAbiVersion, MilaFfiStatus, MilaSnapshotSummary,
        MilaWatchEventKind,
    };
    use mila_runtime::MachineSnapshot;

    #[test]
    fn exposes_stable_abi_version() {
        assert_eq!(mila_ffi_version(), 1);
        let mut version = MilaFfiAbiVersion { major: 0, minor: 0 };
        // SAFETY: version points to writable stack storage.
        let status = unsafe { mila_ffi_get_version(&mut version) };
        assert_eq!(status, MilaFfiStatus::Ok);
        assert_eq!(version, MilaFfiAbiVersion { major: 1, minor: 0 });
    }

    #[test]
    fn rejects_missing_version_storage() {
        // SAFETY: null is intentionally supplied to verify the C ABI guard.
        assert_eq!(
            unsafe { mila_ffi_get_version(std::ptr::null_mut()) },
            MilaFfiStatus::NullInput
        );
    }

    #[test]
    fn validates_terminal_dimensions_at_the_native_boundary() {
        assert_eq!(mila_terminal_validate(120, 40, 1), MilaFfiStatus::Ok);
        assert_eq!(
            mila_terminal_validate(0, 40, 1),
            MilaFfiStatus::InvalidRequest
        );
        assert_eq!(
            mila_terminal_validate(120, 40, 2),
            MilaFfiStatus::InvalidRequest
        );
    }

    #[test]
    fn exposes_only_a_watch_event_tag() {
        let line = br#"{"version":1,"event":"heartbeat"}"#;
        let mut kind = MilaWatchEventKind::Unknown;
        // SAFETY: line and kind are valid for the supplied lengths.
        let status = unsafe { mila_watch_event_kind(line.as_ptr(), line.len(), &mut kind) };
        assert_eq!(status, MilaFfiStatus::Ok);
        assert_eq!(kind, MilaWatchEventKind::Heartbeat);
    }

    #[test]
    fn rejects_malformed_watch_lines() {
        let line = br#"{"version":1,"event":"heartbeat"}"#;
        let mut kind = MilaWatchEventKind::Unknown;
        // SAFETY: line and kind are valid; an excessive length must be rejected.
        let status = unsafe { mila_watch_event_kind(line.as_ptr(), 65_537, &mut kind) };
        assert_eq!(status, MilaFfiStatus::InvalidRequest);
    }

    #[test]
    fn validates_watch_filter_bound() {
        assert_eq!(mila_watch_validate_filters(64, 0), MilaFfiStatus::Ok);
        assert_eq!(
            mila_watch_validate_filters(65, 0),
            MilaFfiStatus::InvalidRequest
        );
    }

    #[test]
    fn validates_push_poke_without_returning_ciphertext() {
        let envelope = br#"{"deployment":"mila.example.test","push_key":"AAAAAAAAAAAAAAAA","delivery_id":"d1","collapse_id":"c1","kind":"refresh","issued_at":100,"nonce":"n1","ciphertext":"Y2lwaGVy"}"#;
        assert_eq!(
            unsafe { super::mila_push_poke_validate(envelope.as_ptr(), envelope.len(), 100) },
            MilaFfiStatus::Ok
        );
        let expired = br#"{"deployment":"mila.example.test","push_key":"AAAAAAAAAAAAAAAA","delivery_id":"d1","collapse_id":"c1","kind":"refresh","issued_at":0,"nonce":"n1","ciphertext":"Y2lwaGVy"}"#;
        assert_eq!(
            unsafe { super::mila_push_poke_validate(expired.as_ptr(), expired.len(), 86_401) },
            MilaFfiStatus::InvalidRequest
        );
    }

    #[test]
    fn rejects_null_trust_document_inputs() {
        let host = std::ffi::CString::new("mgmt.example.test").unwrap();
        // SAFETY: null document is intentional for the ABI guard test.
        assert_eq!(
            unsafe { super::mila_trust_document_validate(std::ptr::null(), 0, host.as_ptr(), 0) },
            MilaFfiStatus::NullInput
        );
    }

    #[test]
    fn validates_snapshot_and_returns_safe_summary() {
        let snapshot = MachineSnapshot::new("mgmt.example.test".into(), Some(443), 42, vec![])
            .unwrap()
            .encode()
            .unwrap();
        let host = std::ffi::CString::new("mgmt.example.test").unwrap();
        let mut summary = MilaSnapshotSummary {
            machine_count: 9,
            saved_at: 0,
        };
        let status = unsafe {
            super::mila_snapshot_validate(
                snapshot.as_ptr(),
                snapshot.len(),
                host.as_ptr(),
                443,
                1,
                &mut summary,
            )
        };
        assert_eq!(status, MilaFfiStatus::Ok);
        assert_eq!(
            summary,
            MilaSnapshotSummary {
                machine_count: 0,
                saved_at: 42
            }
        );
    }

    #[test]
    fn rejects_snapshot_for_wrong_deployment() {
        let snapshot = MachineSnapshot::new("mgmt.example.test".into(), None, 1, vec![])
            .unwrap()
            .encode()
            .unwrap();
        let host = std::ffi::CString::new("other.example.test").unwrap();
        let mut summary = MilaSnapshotSummary {
            machine_count: 0,
            saved_at: 0,
        };
        let status = unsafe {
            super::mila_snapshot_validate(
                snapshot.as_ptr(),
                snapshot.len(),
                host.as_ptr(),
                0,
                0,
                &mut summary,
            )
        };
        assert_eq!(status, MilaFfiStatus::InvalidRequest);
    }
}

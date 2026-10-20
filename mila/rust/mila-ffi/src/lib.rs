//! Narrow C ABI for the Flutter platform bridge.
//!
//! The first migration slice exposes validation only. Ownership of all strings remains
//! with the caller; no secret or private key crosses this boundary.

use mila_model::MilaRoute;
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
        MilaFfiAbiVersion, MilaFfiStatus, MilaWatchEventKind,
    };

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
}

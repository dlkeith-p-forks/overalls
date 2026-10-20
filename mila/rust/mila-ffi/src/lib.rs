//! Narrow C ABI for the Flutter platform bridge.
//!
//! The first migration slice exposes validation only. Ownership of all strings remains
//! with the caller; no secret or private key crosses this boundary.

use mila_model::MilaRoute;
use std::ffi::{c_char, CStr};

/// FFI status values. Zero means success; negative values are stable failures.
#[repr(i32)]
pub enum MilaFfiStatus {
    Ok = 0,
    NullInput = -1,
    InvalidRoute = -2,
    OutputTooSmall = -3,
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

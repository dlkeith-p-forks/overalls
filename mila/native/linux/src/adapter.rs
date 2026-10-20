//! Typed placeholder for generated Rust runtime bindings.

use std::ffi::{c_char, CString};

/// Canonicalizes an activation route through the same Rust FFI entry point used by
/// the other native clients. This keeps Linux from maintaining a second route grammar.
pub fn canonical_route(value: &str) -> Result<String, RuntimeError> {
    let input = CString::new(value).map_err(|_| RuntimeError::InvalidInput)?;
    let mut bytes = vec![0_u8; 2048];
    let mut written = 0_usize;
    let output = mila_ffi::MilaRouteOutput {
        bytes: bytes.as_mut_ptr(),
        capacity: bytes.len(),
        written: &mut written,
    };
    // SAFETY: input is NUL terminated and output points to a writable buffer whose
    // capacity is declared to the bounded C ABI for the duration of this call.
    let status = unsafe { mila_ffi::mila_route_format(input.as_ptr() as *const c_char, output) };
    if status != mila_ffi::MilaFfiStatus::Ok {
        return Err(match status {
            mila_ffi::MilaFfiStatus::InvalidRoute => RuntimeError::InvalidInput,
            _ => RuntimeError::Unavailable,
        });
    }
    bytes.truncate(written);
    String::from_utf8(bytes).map_err(|_| RuntimeError::Unavailable)
}

/// Operations the native UI may request from the generated runtime.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeOperation {
    Bootstrap,
    Refresh,
}

/// A request crossing the native UI/runtime boundary.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeRequest {
    operation: RuntimeOperation,
    payload: Vec<u8>,
}

impl RuntimeRequest {
    pub fn new(operation: RuntimeOperation, payload: impl Into<Vec<u8>>) -> Self {
        Self {
            operation,
            payload: payload.into(),
        }
    }

    pub const fn operation(&self) -> RuntimeOperation {
        self.operation
    }

    pub fn payload(&self) -> &[u8] {
        &self.payload
    }
}

/// A response crossing the native UI/runtime boundary.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeResponse {
    payload: Vec<u8>,
}

impl RuntimeResponse {
    pub fn new(payload: impl Into<Vec<u8>>) -> Self {
        Self {
            payload: payload.into(),
        }
    }

    pub fn payload(&self) -> &[u8] {
        &self.payload
    }
}

/// Errors exposed by the typed adapter seam.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeError {
    Unavailable,
    InvalidInput,
}

/// Host applications replace this with generated UniFFI or C-ABI bindings.
pub trait RuntimeAdapter {
    fn call(&self, request: RuntimeRequest) -> Result<RuntimeResponse, RuntimeError>;
}

/// Explicit placeholder until a host wires the generated runtime binding.
#[derive(Clone, Copy, Debug, Default)]
pub struct UnavailableRuntimeAdapter;

impl RuntimeAdapter for UnavailableRuntimeAdapter {
    fn call(&self, request: RuntimeRequest) -> Result<RuntimeResponse, RuntimeError> {
        let _ = request.operation();
        Err(RuntimeError::Unavailable)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        canonical_route,
        RuntimeAdapter, RuntimeError, RuntimeOperation, RuntimeRequest, UnavailableRuntimeAdapter,
    };

    #[test]
    fn placeholder_fails_closed_without_exposing_payload() {
        let adapter = UnavailableRuntimeAdapter;
        let request = RuntimeRequest::new(RuntimeOperation::Bootstrap, [1_u8, 2, 3]);
        assert_eq!(adapter.call(request), Err(RuntimeError::Unavailable));
    }

    #[test]
    fn canonical_route_uses_shared_core_grammar() {
        assert_eq!(
            canonical_route("overalls://fleet.example/machines").unwrap(),
            "overalls://fleet.example/machines"
        );
        assert_eq!(
            canonical_route("overalls://fleet.example/#commands"),
            Err(RuntimeError::InvalidInput)
        );
    }
}

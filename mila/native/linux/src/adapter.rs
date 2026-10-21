//! Typed in-process runtime boundary for the Linux presentation host.

use std::ffi::{c_char, CString};
use std::sync::{Arc, Mutex};

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

/// Decode a Rust-owned live listing before it reaches GTK. Linux uses the same
/// bounded session decoder as the other native clients, so malformed authority
/// or pagination data cannot become UI state.
pub fn decode_listing(bytes: &[u8]) -> Result<mila_session::MachineListing, RuntimeError> {
    mila_session::decode_listing(bytes).map_err(|_| RuntimeError::InvalidInput)
}

/// Terminal controls exposed to GTK without exposing terminal bytes or pointers.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminalOperation { Attach { from: u64, columns: u16, rows: u16, read_write: bool }, Input { length: usize, read_write: bool }, Resize { columns: u16, rows: u16, read_write: bool } }

pub fn validate_terminal_operation(operation: TerminalOperation) -> Result<(), RuntimeError> {
    let status = match operation {
        TerminalOperation::Attach { from, columns, rows, read_write } => mila_ffi::mila_terminal_attach_validate(from, columns, rows, u8::from(read_write)),
        TerminalOperation::Input { length, read_write } => mila_ffi::mila_terminal_input_validate(length, u8::from(read_write)),
        TerminalOperation::Resize { columns, rows, read_write } => mila_ffi::mila_terminal_resize_validate(columns, rows, u8::from(read_write)),
    };
    if status == mila_ffi::MilaFfiStatus::Ok { Ok(()) } else { Err(RuntimeError::InvalidInput) }
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

pub trait RuntimeAdapter {
    fn call(&self, request: RuntimeRequest) -> Result<RuntimeResponse, RuntimeError>;
}

/// In-process adapter used by the Linux presentation host.
///
/// Bootstrap accepts a bounded `overalls://` route and returns its canonical
/// representation. Refresh accepts a Rust-owned machine snapshot, validates it
/// through the shared FFI contract, retains it in memory, and returns the
/// validated bytes. No network or credential operation is exposed by this
/// adapter; unsupported operations remain fail-closed at the enum boundary.
#[derive(Clone, Debug)]
pub struct InProcessRuntimeAdapter {
    host: CString,
    port: Option<u16>,
    snapshot: Arc<Mutex<Option<Vec<u8>>>>,
}

impl InProcessRuntimeAdapter {
    pub fn new(host: &str, port: Option<u16>) -> Result<Self, RuntimeError> {
        let host = CString::new(host).map_err(|_| RuntimeError::InvalidInput)?;
        Ok(Self {
            host,
            port,
            snapshot: Arc::new(Mutex::new(None)),
        })
    }

    pub fn snapshot(&self) -> Result<Option<Vec<u8>>, RuntimeError> {
        self.snapshot
            .lock()
            .map(|value| value.clone())
            .map_err(|_| RuntimeError::Unavailable)
    }
}

impl RuntimeAdapter for InProcessRuntimeAdapter {
    fn call(&self, request: RuntimeRequest) -> Result<RuntimeResponse, RuntimeError> {
        match request.operation() {
            RuntimeOperation::Bootstrap => {
                let route = std::str::from_utf8(request.payload())
                    .map_err(|_| RuntimeError::InvalidInput)?;
                Ok(RuntimeResponse::new(canonical_route(route)?.into_bytes()))
            }
            RuntimeOperation::Refresh => {
                let payload = request.payload();
                let mut summary = mila_ffi::MilaSnapshotSummary {
                    machine_count: 0,
                    saved_at: 0,
                };
                let status = unsafe {
                    mila_ffi::mila_snapshot_validate(
                        payload.as_ptr(),
                        payload.len(),
                        self.host.as_ptr(),
                        self.port.unwrap_or_default(),
                        u8::from(self.port.is_some()),
                        &mut summary,
                    )
                };
                if status != mila_ffi::MilaFfiStatus::Ok {
                    return Err(RuntimeError::InvalidInput);
                }
                self.snapshot
                    .lock()
                    .map_err(|_| RuntimeError::Unavailable)?
                    .replace(payload.to_vec());
                Ok(RuntimeResponse::new(payload.to_vec()))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        canonical_route, InProcessRuntimeAdapter, RuntimeAdapter, RuntimeError, RuntimeOperation,
        RuntimeRequest,
    };

    #[test]
    fn bootstrap_canonicalizes_routes() {
        let adapter = InProcessRuntimeAdapter::new("fleet.example", None).unwrap();
        let request = RuntimeRequest::new(
            RuntimeOperation::Bootstrap,
            b"overalls://fleet.example/machines".to_vec(),
        );
        assert_eq!(
            adapter.call(request).unwrap().payload(),
            b"overalls://fleet.example/machines"
        );
    }

    #[test]
    fn refresh_rejects_invalid_snapshot_and_does_not_retain_it() {
        let adapter = InProcessRuntimeAdapter::new("fleet.example", None).unwrap();
        let request = RuntimeRequest::new(RuntimeOperation::Refresh, [1_u8, 2, 3]);
        assert_eq!(adapter.call(request), Err(RuntimeError::InvalidInput));
        assert_eq!(adapter.snapshot().unwrap(), None);
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

    #[test]
    fn terminal_controls_use_shared_ffi_validation() {
        assert!(super::validate_terminal_operation(super::TerminalOperation::Attach { from: 0, columns: 80, rows: 24, read_write: true }).is_ok());
        assert!(super::validate_terminal_operation(super::TerminalOperation::Resize { columns: 0, rows: 24, read_write: true }).is_err());
        assert!(super::validate_terminal_operation(super::TerminalOperation::Input { length: 1, read_write: false }).is_err());
        assert!(super::validate_terminal_operation(super::TerminalOperation::Input { length: 4, read_write: true }).is_ok());
    }

    #[test]
    fn listing_uses_shared_bounded_decoder() {
        let bytes =
            br#"{"version":1,"status":"succeeded","result":{"items":[],"next_cursor":null}}"#;
        let listing = super::decode_listing(bytes).unwrap();
        assert!(listing.machines().is_empty());
        assert!(!listing.has_more());
        assert!(super::decode_listing(br#"{}"#).is_err());
    }
}

//! Typed placeholder for generated Rust runtime bindings.

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
        RuntimeAdapter, RuntimeError, RuntimeOperation, RuntimeRequest, UnavailableRuntimeAdapter,
    };

    #[test]
    fn placeholder_fails_closed_without_exposing_payload() {
        let adapter = UnavailableRuntimeAdapter;
        let request = RuntimeRequest::new(RuntimeOperation::Bootstrap, [1_u8, 2, 3]);
        assert_eq!(adapter.call(request), Err(RuntimeError::Unavailable));
    }
}

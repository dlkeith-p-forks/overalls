//! One current, identity-free OTLP trace for the disposable collector test.

use std::env;
use std::fs;
use std::io;
use std::time::{SystemTime, UNIX_EPOCH};

const TRACE_ID: [u8; 16] = [
    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
];
const SPAN_ID: [u8; 8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77];

fn varint(mut value: u64, output: &mut Vec<u8>) {
    while value >= 0x80 {
        output.push((value as u8) | 0x80);
        value >>= 7;
    }
    output.push(value as u8);
}

fn bytes(field: u32, value: &[u8], output: &mut Vec<u8>) {
    varint((u64::from(field) << 3) | 2, output);
    varint(value.len() as u64, output);
    output.extend_from_slice(value);
}

fn fixed64(field: u32, value: u64, output: &mut Vec<u8>) {
    varint((u64::from(field) << 3) | 1, output);
    output.extend_from_slice(&value.to_le_bytes());
}

// @cc [owner:ghuntley,label:verification;security] otel-trace-replay-fixture
// Emit exactly one current span with fixed trace and span IDs, a fixed name,
// and no attributes or guest identity. This payload only probes the worker
// collector queue and Tempo replay in an isolated NixOS test.
fn trace_request(now_ns: u64, trace_id: [u8; 16]) -> Vec<u8> {
    let mut span = Vec::new();
    bytes(1, &trace_id, &mut span);
    bytes(2, &SPAN_ID, &mut span);
    bytes(5, b"otel.replay.fixture", &mut span);
    fixed64(7, now_ns, &mut span);
    fixed64(8, now_ns + 1_000_000, &mut span);

    let mut scope_spans = Vec::new();
    bytes(2, &span, &mut scope_spans);
    let mut resource_spans = Vec::new();
    bytes(2, &scope_spans, &mut resource_spans);
    let mut request = Vec::new();
    bytes(1, &resource_spans, &mut request);
    request
}

fn main() -> io::Result<()> {
    let mut arguments = env::args().skip(1);
    let path = arguments
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "expected output path"))?;
    let mut trace_id = TRACE_ID;
    if let Some(suffix) = arguments.next() {
        trace_id[15] = suffix
            .parse::<u8>()
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
    }
    if arguments.next().is_some() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "unexpected argument"));
    }
    let now_ns: u64 = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?
        .as_nanos()
        .try_into()
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    fs::write(path, trace_request(now_ns, trace_id))
}

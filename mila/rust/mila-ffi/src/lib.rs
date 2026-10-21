//! Narrow C ABI for the Flutter platform bridge.
//!
//! The first migration slice exposes validation only. Ownership of all strings remains
//! with the caller; no secret or private key crosses this boundary.

pub mod session;

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

/// Maximum terminal input accepted by the native boundary (bytes remain owned by the host).
pub const MILA_TERMINAL_MAX_INPUT: usize = 1 << 20;

/// Validates a terminal attach request without crossing machine or terminal identifiers.
#[no_mangle]
pub extern "C" fn mila_terminal_attach_validate(
    from: u64,
    columns: u16,
    rows: u16,
    read_write: u8,
) -> MilaFfiStatus {
    if read_write > 1 {
        return MilaFfiStatus::InvalidRequest;
    }
    let request = TerminalAttachRequest {
        machine_id: uuid::Uuid::nil(),
        session_id: uuid::Uuid::nil(),
        from,
        columns,
        rows,
        read_write: read_write == 1,
    };
    request
        .validate()
        .map_or(MilaFfiStatus::InvalidRequest, |_| MilaFfiStatus::Ok)
}

/// Validates a terminal input length and permission bit. Input bytes never cross this ABI.
#[no_mangle]
pub extern "C" fn mila_terminal_input_validate(length: usize, read_write: u8) -> MilaFfiStatus {
    if read_write > 1 || length > MILA_TERMINAL_MAX_INPUT || (read_write == 0 && length != 0) {
        MilaFfiStatus::InvalidRequest
    } else {
        MilaFfiStatus::Ok
    }
}

/// Validates a terminal resize request.
#[no_mangle]
pub extern "C" fn mila_terminal_resize_validate(
    columns: u16,
    rows: u16,
    read_write: u8,
) -> MilaFfiStatus {
    mila_terminal_attach_validate(0, columns, rows, read_write)
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

/// @cc [owner:ghuntley,label:security;protocol] mila-ffi-bounded-output
/// Parses an `overalls://` route and writes its canonical spelling to `output`.
///
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

/// Bit flags describing actions permitted for one cached machine.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MilaMachineActions {
    pub bits: u16,
}

/// @cc [owner:ghuntley,label:security;protocol] mila-session-command-bounded
/// Formats a catalogued machine action with bounded, canonical output.
/// Native callers MUST receive only catalogued commands; credentials and arbitrary payloads MUST NOT cross this ABI.
///
/// # Safety
/// Pointers must be valid NUL-terminated strings and `output` must reference writable storage.
#[no_mangle]
pub unsafe extern "C" fn mila_session_command_format(
    action: *const c_char,
    machine_id: *const c_char,
    request_id: *const c_char,
    output: MilaRouteOutput,
) -> MilaFfiStatus {
    if action.is_null()
        || machine_id.is_null()
        || output.bytes.is_null()
        || output.written.is_null()
    {
        return MilaFfiStatus::NullInput;
    }
    let text = |ptr: *const c_char| {
        CStr::from_ptr(ptr)
            .to_str()
            .map(str::to_owned)
            .map_err(|_| MilaFfiStatus::InvalidRequest)
    };
    let action = match text(action) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let machine = match text(machine_id) {
        Ok(v) => v,
        Err(e) => return e,
    };
    if mila_model::Identifier::parse(&machine).is_err() {
        return MilaFfiStatus::InvalidRequest;
    }
    let mutation = match action.as_str() {
        "show" => false,
        "start" | "stop" | "pause" | "resume" | "unpause" | "pin" | "unpin" | "rm" => true,
        _ => return MilaFfiStatus::InvalidRequest,
    };
    let mut line = format!("{action} {machine} --json");
    if mutation {
        if request_id.is_null() {
            return MilaFfiStatus::InvalidRequest;
        }
        let id = match text(request_id) {
            Ok(v) => v,
            Err(e) => return e,
        };
        if mila_model::RequestId::parse(&id).is_err() {
            return MilaFfiStatus::InvalidRequest;
        }
        line.push_str(" --request-id=");
        line.push_str(&id);
    }
    let command = match mila_protocol::Command::parse(&line).and_then(|c| c.format()) {
        Ok(v) => v,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let bytes = command.as_bytes();
    if bytes.len() > output.capacity {
        return MilaFfiStatus::OutputTooSmall;
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), output.bytes, bytes.len());
    if output.capacity > bytes.len() {
        *output.bytes.add(bytes.len()) = 0;
    }
    *output.written = bytes.len();
    MilaFfiStatus::Ok
}

/// Closed thread command tags. Arguments and payloads are never returned across the ABI.
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MilaThreadCommandKind {
    Unknown = 0,
    List = 1,
    Show = 2,
    Turns = 3,
    Prompt = 4,
    Answer = 5,
    PlanApprove = 6,
    PlanRevise = 7,
    Mode = 8,
    Read = 9,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MilaMachineCommandKind {
    Unknown = 0,
    List = 1,
    Show = 2,
    New = 3,
    Resize = 4,
    Start = 5,
    Stop = 6,
    Pause = 7,
    Resume = 8,
    Delete = 9,
    ShareAdd = 10,
    ShareRemove = 11,
    WebShow = 12,
    WebSet = 13,
}

/// Projects a parsed machine-management command to a closed operation tag.
///
/// # Safety
/// `line` and `out_kind` must be valid non-null pointers; `line` must be a
/// NUL-terminated UTF-8 string and `out_kind` writable for one value.
#[no_mangle]
pub unsafe extern "C" fn mila_machine_command_kind(
    line: *const c_char,
    out_kind: *mut MilaMachineCommandKind,
) -> MilaFfiStatus {
    if line.is_null() || out_kind.is_null() {
        return MilaFfiStatus::NullInput;
    }
    let line = match CStr::from_ptr(line).to_str() {
        Ok(value) => value,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let command = match mila_protocol::Command::parse(line) {
        Ok(command) => command.command,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let kind = match command.as_str() {
        "ls" => MilaMachineCommandKind::List,
        "show" => MilaMachineCommandKind::Show,
        "new" => MilaMachineCommandKind::New,
        "resize" => MilaMachineCommandKind::Resize,
        "start" => MilaMachineCommandKind::Start,
        "stop" => MilaMachineCommandKind::Stop,
        "pause" => MilaMachineCommandKind::Pause,
        "resume" | "unpause" => MilaMachineCommandKind::Resume,
        "rm" => MilaMachineCommandKind::Delete,
        "share add" => MilaMachineCommandKind::ShareAdd,
        "share remove" => MilaMachineCommandKind::ShareRemove,
        "web show" => MilaMachineCommandKind::WebShow,
        "web set" => MilaMachineCommandKind::WebSet,
        _ => return MilaFfiStatus::InvalidRequest,
    };
    *out_kind = kind;
    MilaFfiStatus::Ok
}

/// Parses a bounded Porsche command and projects only its catalogued thread operation.
/// The caller retains ownership of the command bytes; no argument or payload is returned.
///
/// # Safety
/// `line` and `out_kind` must be valid non-null pointers. `line` must point to a
/// NUL-terminated UTF-8 C string and `out_kind` must be writable for one value.
#[no_mangle]
pub unsafe extern "C" fn mila_thread_command_kind(
    line: *const c_char,
    out_kind: *mut MilaThreadCommandKind,
) -> MilaFfiStatus {
    if line.is_null() || out_kind.is_null() {
        return MilaFfiStatus::NullInput;
    }
    let line = match CStr::from_ptr(line).to_str() {
        Ok(value) => value,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let command = match mila_protocol::Command::parse(line) {
        Ok(command) => command,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let kind = match command.command.as_str() {
        "thread ls" => MilaThreadCommandKind::List,
        "thread show" => MilaThreadCommandKind::Show,
        "thread turns" => MilaThreadCommandKind::Turns,
        "thread prompt" => MilaThreadCommandKind::Prompt,
        "thread answer" => MilaThreadCommandKind::Answer,
        "thread plan approve" => MilaThreadCommandKind::PlanApprove,
        "thread plan revise" => MilaThreadCommandKind::PlanRevise,
        "thread mode" => MilaThreadCommandKind::Mode,
        "thread read" => MilaThreadCommandKind::Read,
        _ => return MilaFfiStatus::InvalidRequest,
    };
    *out_kind = kind;
    MilaFfiStatus::Ok
}

/// Projects the closed action policy for a machine in a validated snapshot.
///
/// # Safety
/// `bytes` and `host` must be valid for the supplied length and NUL-terminated respectively; `out_actions` must be writable.
#[no_mangle]
pub unsafe extern "C" fn mila_snapshot_machine_actions(
    bytes: *const u8,
    length: usize,
    host: *const c_char,
    port: u16,
    has_port: u8,
    index: u32,
    out_actions: *mut MilaMachineActions,
) -> MilaFfiStatus {
    if bytes.is_null() || host.is_null() || out_actions.is_null() || has_port > 1 {
        return MilaFfiStatus::NullInput;
    }
    let host = match CStr::from_ptr(host).to_str() {
        Ok(v) => v,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let snapshot = match MachineSnapshot::decode(
        std::slice::from_raw_parts(bytes, length),
        host,
        (has_port == 1).then_some(port),
    ) {
        Ok(v) => v,
        Err(_) => return MilaFfiStatus::InvalidRequest,
    };
    let Some(machine) = snapshot.machines.get(index as usize) else {
        return MilaFfiStatus::InvalidRequest;
    };
    let bits = machine
        .available_actions()
        .into_iter()
        .fold(0u16, |bits, action| bits | (1 << action as u16));
    *out_actions = MilaMachineActions { bits };
    MilaFfiStatus::Ok
}

/// JNI bridge for the bounded live-session ABI. The signer object is held only for
/// the synchronous connect call and must expose `sign(byte[]) -> byte[]`.
struct AndroidSigner {
    vm: jni::JavaVM,
    signer: jni::objects::GlobalRef,
}
unsafe extern "C" fn android_sign(
    context: usize,
    message: *const u8,
    length: usize,
    output: *mut u8,
) -> i32 {
    let state = &*(context as *const AndroidSigner);
    let mut env = match state.vm.attach_current_thread() {
        Ok(v) => v,
        Err(_) => return -1,
    };
    let bytes = if message.is_null() || output.is_null() || length == 0 || length > 65_536 {
        return -1;
    } else {
        std::slice::from_raw_parts(message, length)
    };
    let input = match env.byte_array_from_slice(bytes) {
        Ok(v) => v,
        Err(_) => return -1,
    };
    let value = match env.call_method(
        &state.signer,
        "sign",
        "([B)[B",
        &[jni::objects::JValue::Object(&input.into())],
    ) {
        Ok(v) => v,
        Err(_) => return -1,
    };
    let object = match value.l() {
        Ok(v) => v,
        Err(_) => return -1,
    };
    let array = jni::objects::JByteArray::from(object);
    let signature = match env.convert_byte_array(array) {
        Ok(v) if v.len() == 64 => v,
        _ => return -1,
    };
    std::ptr::copy_nonoverlapping(signature.as_ptr(), output, 64);
    0
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionConnect(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    trust: jni::objects::JByteArray<'_>,
    host: jni::objects::JString<'_>,
    public_key: jni::objects::JString<'_>,
    port: jni::sys::jint,
    timeout_ms: jni::sys::jint,
    signer: jni::objects::JObject<'_>,
) -> jni::sys::jlong {
    if port <= 0 || port > u16::MAX as i32 || timeout_ms <= 0 {
        return 0;
    }
    let trust = match env.convert_byte_array(trust) {
        Ok(v) => v,
        Err(_) => return 0,
    };
    let host = match env.get_string(&host) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return 0,
    };
    let public_key = match env.get_string(&public_key) {
        Ok(v) => v.to_bytes().to_vec(),
        Err(_) => return 0,
    };
    let global = match env.new_global_ref(signer) {
        Ok(v) => v,
        Err(_) => return 0,
    };
    let vm = match env.get_java_vm() {
        Ok(v) => v,
        Err(_) => return 0,
    };
    let state = Box::new(AndroidSigner { vm, signer: global });
    let context = Box::into_raw(state) as usize;
    let mut handle = 0u64;
    let status = unsafe {
        session::mila_session_connect(
            trust.as_ptr(),
            trust.len(),
            host.as_ptr(),
            host.len(),
            public_key.as_ptr(),
            public_key.len(),
            port as u16,
            timeout_ms as u32,
            Some(android_sign),
            context,
            &mut handle,
        )
    };
    unsafe {
        drop(Box::from_raw(context as *mut AndroidSigner));
    }
    if status == session::SessionStatus::Ok {
        handle as jni::sys::jlong
    } else {
        0
    }
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionRead(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
    more: jni::sys::jboolean,
) -> jni::sys::jint {
    session::mila_session_read_machines(handle as u64, more) as jni::sys::jint
}

fn session_copy(env: &mut jni::JNIEnv<'_>, handle: u64, snapshot: bool) -> jni::sys::jbyteArray {
    let mut size = 0usize;
    let status = unsafe {
        if snapshot {
            session::mila_session_snapshot(handle, 0, std::ptr::null_mut(), 0, &mut size)
        } else {
            session::mila_session_listing(handle, std::ptr::null_mut(), 0, &mut size)
        }
    };
    if status != session::SessionStatus::SmallBuffer || size == 0 || size > 8 * 1024 * 1024 {
        return std::ptr::null_mut();
    }
    let mut data = vec![0u8; size];
    let status = unsafe {
        if snapshot {
            session::mila_session_snapshot(handle, 0, data.as_mut_ptr(), size, &mut size)
        } else {
            session::mila_session_listing(handle, data.as_mut_ptr(), size, &mut size)
        }
    };
    if status != session::SessionStatus::Ok {
        return std::ptr::null_mut();
    }
    match env.byte_array_from_slice(&data[..size]) {
        Ok(v) => v.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionListing(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
) -> jni::sys::jbyteArray {
    session_copy(&mut env, handle as u64, false)
}
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionSnapshot(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
) -> jni::sys::jbyteArray {
    session_copy(&mut env, handle as u64, true)
}
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeSessionClose(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    handle: jni::sys::jlong,
) -> jni::sys::jint {
    session::mila_session_close(handle as u64) as jni::sys::jint
}

/// JNI ABI version for the Android native client.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeAbiVersion(
    _env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
) -> jni::sys::jint {
    1
}

/// JNI route canonicalization delegated to the Rust route parser.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeCanonicalRoute(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    value: jni::objects::JString<'_>,
) -> jni::sys::jstring {
    let input: String = match env.get_string(&value) {
        Ok(v) => v.into(),
        Err(_) => return std::ptr::null_mut(),
    };
    let route = match MilaRoute::parse(&input) {
        Ok(route) => route.format(),
        Err(_) => return std::ptr::null_mut(),
    };
    match env.new_string(route) {
        Ok(output) => output.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// JNI projection of the closed thread command catalogue. Only the stable
/// operation tag crosses the boundary; arguments and payloads remain Rust
/// owned. Returns -1 for malformed or unknown commands.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeThreadCommandKind(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    value: jni::objects::JString<'_>,
) -> jni::sys::jint {
    let input = match env.get_string(&value) {
        Ok(value) => match std::ffi::CString::new(value.to_bytes()) {
            Ok(value) => value,
            Err(_) => return -1,
        },
        Err(_) => return -1,
    };
    let mut kind = MilaThreadCommandKind::Unknown;
    let status = unsafe { mila_thread_command_kind(input.as_ptr(), &mut kind) };
    if status != MilaFfiStatus::Ok {
        return -1;
    }
    kind as jni::sys::jint
}

/// JNI projection of the closed machine-command catalog. Returns -1 for
/// malformed or unknown commands; command arguments remain Rust-owned.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeMachineCommandKind(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    value: jni::objects::JString<'_>,
) -> jni::sys::jint {
    let input = match env.get_string(&value) {
        Ok(value) => match std::ffi::CString::new(value.to_bytes()) {
            Ok(value) => value,
            Err(_) => return -1,
        },
        Err(_) => return -1,
    };
    let mut kind = MilaMachineCommandKind::Unknown;
    let status = unsafe { mila_machine_command_kind(input.as_ptr(), &mut kind) };
    if status != MilaFfiStatus::Ok { return -1; }
    kind as jni::sys::jint
}

/// JNI projection of the bounded machine action policy.  The returned value is
/// a bit mask (one bit per `MachineAction` discriminant), or `-1` when the
/// snapshot, deployment, or index is invalid.  Machine records never cross
/// this boundary; Android receives only the closed policy result.
#[no_mangle]
pub extern "system" fn Java_dev_overalls_mila_nativeui_MilaRustFfi_nativeMachineActions(
    mut env: jni::JNIEnv<'_>,
    _class: jni::objects::JClass<'_>,
    bytes: jni::objects::JByteArray<'_>,
    host: jni::objects::JString<'_>,
    port: jni::sys::jint,
    has_port: jni::sys::jboolean,
    index: jni::sys::jint,
) -> jni::sys::jint {
    if port < 0 || port > u16::MAX as jni::sys::jint || index < 0 || has_port > 1 {
        return -1;
    }
    let bytes = match env.convert_byte_array(bytes) {
        Ok(value) => value,
        Err(_) => return -1,
    };
    let host = match env.get_string(&host) {
        Ok(value) => value,
        Err(_) => return -1,
    };
    let host = match std::ffi::CString::new(host.to_bytes()) {
        Ok(value) => value,
        Err(_) => return -1,
    };
    let mut actions = MilaMachineActions { bits: 0 };
    let status = unsafe {
        mila_snapshot_machine_actions(
            bytes.as_ptr(),
            bytes.len(),
            host.as_ptr(),
            port as u16,
            has_port,
            index as u32,
            &mut actions,
        )
    };
    if status == MilaFfiStatus::Ok {
        actions.bits as jni::sys::jint
    } else {
        -1
    }
}

#[cfg(test)]
mod tests {
    use super::{
        mila_ffi_get_version, mila_ffi_version, mila_machine_command_kind,
        mila_terminal_attach_validate, mila_terminal_input_validate, mila_terminal_resize_validate,
        mila_terminal_validate, mila_thread_command_kind, mila_watch_event_kind,
        mila_watch_validate_filters, MilaFfiAbiVersion, MilaFfiStatus, MilaMachineCommandKind,
        MilaSnapshotSummary, MilaThreadCommandKind, MilaWatchEventKind,
    };
    use mila_runtime::MachineSnapshot;

    /// Keep the C ABI route writer aligned with the vectors consumed by every
    /// native client. This catches drift where a platform wrapper accepts a
    /// route that the shared boundary cannot canonicalize.
    #[test]
    fn formats_shared_route_fixture_vectors() {
        let fixture = include_str!("../../../../protocol/test/fixtures/app_routes.json");
        let document: serde_json::Value = serde_json::from_str(fixture).expect("route fixture");
        for vector in document["accepted"].as_array().expect("accepted vectors") {
            let input = std::ffi::CString::new(vector["input"].as_str().unwrap()).unwrap();
            let expected = vector["canonical"].as_str().unwrap().as_bytes();
            let mut bytes = vec![0_u8; expected.len() + 1];
            let mut written = 0_usize;
            let status = unsafe {
                super::mila_route_format(
                    input.as_ptr(),
                    super::MilaRouteOutput {
                        bytes: bytes.as_mut_ptr(),
                        capacity: bytes.len(),
                        written: &mut written,
                    },
                )
            };
            assert_eq!(status, MilaFfiStatus::Ok);
            assert_eq!(written, expected.len());
            assert_eq!(&bytes[..written], expected);
        }
    }

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
    fn projects_thread_command_catalog_without_payloads() {
        let line = std::ffi::CString::new("thread ls").unwrap();
        let mut kind = MilaThreadCommandKind::Unknown;
        assert_eq!(
            unsafe { mila_thread_command_kind(line.as_ptr(), &mut kind) },
            MilaFfiStatus::Ok
        );
        assert_eq!(kind, MilaThreadCommandKind::List);
        let unknown = std::ffi::CString::new("thread delete abc --json").unwrap();
        let mut kind = MilaThreadCommandKind::Unknown;
        assert_eq!(
            unsafe { mila_thread_command_kind(unknown.as_ptr(), &mut kind) },
            MilaFfiStatus::InvalidRequest
        );
    }

    #[test]
    fn projects_machine_management_catalog_without_payloads() {
        for (line, expected) in [("ls", MilaMachineCommandKind::List)] {
            let line = std::ffi::CString::new(line).unwrap();
            let mut kind = MilaMachineCommandKind::Unknown;
            assert_eq!(
                unsafe { mila_machine_command_kind(line.as_ptr(), &mut kind) },
                MilaFfiStatus::Ok
            );
            assert_eq!(kind, expected);
        }
    }

    #[test]
    fn validates_terminal_control_operations() {
        assert_eq!(
            mila_terminal_attach_validate(7, 120, 40, 1),
            MilaFfiStatus::Ok
        );
        assert_eq!(mila_terminal_resize_validate(120, 40, 1), MilaFfiStatus::Ok);
        assert_eq!(
            mila_terminal_resize_validate(0, 40, 1),
            MilaFfiStatus::InvalidRequest
        );
        assert_eq!(mila_terminal_input_validate(0, 0), MilaFfiStatus::Ok);
        assert_eq!(
            mila_terminal_input_validate(1, 0),
            MilaFfiStatus::InvalidRequest
        );
        assert_eq!(mila_terminal_input_validate(1 << 20, 1), MilaFfiStatus::Ok);
        assert_eq!(
            mila_terminal_input_validate((1 << 20) + 1, 1),
            MilaFfiStatus::InvalidRequest
        );
    }

    /// Property-style boundary check: every dimension in the accepted rectangle is valid,
    /// while every zero dimension and permission outside {0,1} is refused.
    #[test]
    fn terminal_dimension_property_is_bounded() {
        for columns in [0_u16, 1, 80, 4096, 4097, u16::MAX] {
            for rows in [0_u16, 1, 24, 512, 513, u16::MAX] {
                let valid = (1..=4096).contains(&columns) && (1..=512).contains(&rows);
                assert_eq!(
                    mila_terminal_resize_validate(columns, rows, 1) == MilaFfiStatus::Ok,
                    valid
                );
            }
        }
        for permission in [2_u8, u8::MAX] {
            assert_eq!(
                mila_terminal_resize_validate(80, 24, permission),
                MilaFfiStatus::InvalidRequest
            );
        }
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

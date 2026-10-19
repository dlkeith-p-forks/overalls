//! Windows guest editor broker.
//!
//! This process is a SYSTEM-owned gateway.  It obtains the physical boot
//! identity from MMDS and admits Lilly's closed preface. Its separate fixed
//! custodian mode independently revalidates admission, reconciles the account,
//! and retains exact worker/job custody across gateway stream and process loss.
//! The implementation deliberately keeps the Windows listener separate from
//! the Linux systemd broker; no Windows image is editor-capable until its
//! package and manifest promote this code.

use overalls_vscode_web_broker::windows::{
    Package, QuarantinedJob, Worker, package_file, private_directory, read_private_optional,
    require_system, resolve_account, write_private,
};
use overalls_vscode_web_broker::windows_ipc as ipc;
use overalls_vscode_web_broker::windows_model::{
    CustodianAccounts, HeldWorkerDecision, ProcessIdentity, WorkerIdentity, WorkerPath,
    held_worker_decision,
};
use overalls_vscode_web_broker::windows_pipe::Pipe;
use overalls_vscode_web_broker::{
    Binding, Boot, Descriptor, PORT, Preface, Refusal, mmds, ready, validate,
};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::net::{Shutdown, TcpListener, TcpStream};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const STARTUP: Duration = Duration::from_secs(20);
const MAX_CONNECTIONS: usize = 64;
const RECEIPT_MAXIMUM: usize = 16 * 1024;

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Configuration {
    descriptor: Descriptor,
    node: String,
    server: String,
    system_root: String,
    account_authorizer: String,
    state_directory: String,
    ca_bundle: String,
    worker_path: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Receipt {
    version: u8,
    worker_key: String,
    binding: Binding,
    process: ProcessIdentity,
}

enum WorkerState {
    Empty,
    Live(Worker),
    // Failed cleanup retains its job handle and its capacity slot. It cannot be
    // reused or evicted by a later request; custodian exit remains kill-on-close.
    Quarantined(Worker),
    QuarantinedLaunch(QuarantinedJob),
}

struct Runtime {
    configuration: Configuration,
    descriptor: Descriptor,
    boot: Boot,
    package: Package,
    state: overalls_vscode_web_broker::windows_model::LocalPath,
    workers: CustodianAccounts<WorkerState>,
    endpoint: String,
    executable: overalls_vscode_web_broker::windows_model::LocalPath,
    connections: AtomicUsize,
}

fn event(name: &'static str, reason: Option<Refusal>) {
    // Diagnostics intentionally contain fixed enums only.
    match reason {
        Some(reason) => eprintln!(
            "{{\"service\":\"windows-editor-broker\",\"event\":\"{name}\",\"reason\":\"{}\"}}",
            reason.name()
        ),
        None => eprintln!("{{\"service\":\"windows-editor-broker\",\"event\":\"{name}\"}}"),
    }
}

fn local(value: &str) -> Result<overalls_vscode_web_broker::windows_model::LocalPath, Refusal> {
    overalls_vscode_web_broker::windows_model::LocalPath::parse(value).map_err(|_| Refusal::Package)
}

fn read_configuration(path: &Path) -> Result<Configuration, Refusal> {
    let path_text = path.to_str().ok_or(Refusal::Package)?;
    let checked = local(path_text)?;
    package_file(&checked)?;
    let bytes = fs::read(path).map_err(|_| Refusal::Package)?;
    if bytes.is_empty() || bytes.len() > RECEIPT_MAXIMUM {
        return Err(Refusal::Package);
    }
    let configuration: Configuration =
        serde_json::from_slice(&bytes).map_err(|_| Refusal::Package)?;
    configuration.descriptor.validate()?;
    if configuration.system_root != r"C:\Windows" {
        return Err(Refusal::Package);
    }
    for value in [
        &configuration.node,
        &configuration.server,
        &configuration.system_root,
        &configuration.account_authorizer,
        &configuration.state_directory,
        &configuration.ca_bundle,
    ] {
        local(value)?;
    }
    package_file(&local(&configuration.account_authorizer)?)?;
    WorkerPath::parse(&configuration.worker_path)?;
    Ok(configuration)
}

fn run_authorizer(path: &Path, binding: &Binding, deadline: Instant) -> Result<(), Refusal> {
    let mut child = Command::new(path)
        .args([
            "--ensure-account",
            binding.username.as_str(),
            binding.uid.to_string().as_str(),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| Refusal::Account)?;
    loop {
        if let Some(status) = child.try_wait().map_err(|_| Refusal::Account)? {
            return status.success().then_some(()).ok_or(Refusal::Account);
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(Refusal::Startup);
        }
        thread::sleep(Duration::from_millis(20));
    }
}

fn receipt_path(
    state: &overalls_vscode_web_broker::windows_model::LocalPath,
    uid: u32,
) -> Result<overalls_vscode_web_broker::windows_model::LocalPath, Refusal> {
    local(&format!(r"{}\u{}\worker.json", state.as_str(), uid))
}

fn with_slot<T>(
    slot: &Mutex<WorkerState>,
    deadline: Instant,
    operation: impl FnOnce(&mut WorkerState) -> Result<T, Refusal>,
) -> Result<T, Refusal> {
    while Instant::now() < deadline {
        match slot.try_lock() {
            Ok(mut guard) => return operation(&mut guard),
            Err(std::sync::TryLockError::Poisoned(_)) => return Err(Refusal::Custody),
            Err(std::sync::TryLockError::WouldBlock) => thread::sleep(Duration::from_millis(10)),
        }
    }
    Err(Refusal::Startup)
}

fn worker_identity(runtime: &Runtime, preface: &Preface) -> Result<WorkerIdentity, Refusal> {
    let sid = resolve_account(preface.binding.uid, &preface.binding.username)?;
    WorkerIdentity::admitted(preface, &runtime.boot, &runtime.descriptor, sid)
}

fn receipt_matches(receipt: &Receipt, identity: &WorkerIdentity, runtime: &Runtime) -> bool {
    receipt.version == 1
        && receipt.worker_key == identity.key()
        && identity.matches_retained_binding(&receipt.binding, &runtime.boot, &runtime.descriptor)
}

/// @cc [owner:ghuntley,label:security;recovery] windows-editor-record-launch-or-stop
/// The custodian MUST retain a kill-on-close job before atomic child creation.
/// It MUST publish the complete private receipt before resume/map commitment.
/// Any failure MUST terminate and account the whole owned job; cleanup failure
/// MUST retain a quarantined handle/slot and surface refusal, never silently evict.
fn launch_and_record(
    runtime: &Runtime,
    identity: WorkerIdentity,
    binding: &Binding,
    path: &overalls_vscode_web_broker::windows_model::LocalPath,
    slot: &mut WorkerState,
    deadline: Instant,
) -> Result<(), Refusal> {
    let worker_key = identity.key();
    let mut worker = match Worker::launch(identity, &runtime.package) {
        Ok(worker) => worker,
        Err(failure) => {
            if let Some(job) = failure.quarantine {
                *slot = WorkerState::QuarantinedLaunch(job);
            }
            return Err(failure.reason);
        }
    };
    let recorded = (|| {
        let receipt = Receipt {
            version: 1,
            worker_key,
            binding: binding.clone(),
            process: worker.process_identity(),
        };
        let encoded = serde_json::to_vec(&receipt).map_err(|_| Refusal::Custody)?;
        write_private(path, &encoded)?;
        worker.resume()?;
        while Instant::now() < deadline {
            if probe(&worker, binding, deadline).is_ok() {
                return Ok(());
            }
            thread::sleep(Duration::from_millis(50));
        }
        Err(Refusal::Readiness)
    })();
    if let Err(reason) = recorded {
        if let Err(cleanup) = worker.terminate() {
            *slot = WorkerState::Quarantined(worker);
            return Err(cleanup);
        }
        // Removal is only of the exact account's private receipt, after all
        // owned processes have drained. An absent unpublished receipt is fine.
        match fs::remove_file(path.as_str()) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => {
                *slot = WorkerState::Quarantined(worker);
                return Err(Refusal::Custody);
            }
        }
        return Err(reason);
    }
    *slot = WorkerState::Live(worker);
    Ok(())
}

fn probe(worker: &Worker, binding: &Binding, deadline: Instant) -> Result<(), Refusal> {
    if Instant::now() >= deadline {
        return Err(Refusal::Readiness);
    }
    let mut pipe = worker.connect()?;
    let request = format!(
        "GET /version HTTP/1.0\r\nHost: {}\r\nConnection: close\r\n\r\n",
        binding.editor_origin.trim_start_matches("https://")
    );
    let request = request.as_bytes();
    let mut sent = 0;
    while sent < request.len() {
        let written = pipe
            .write_deadline(&request[sent..], deadline)
            .map_err(|_| Refusal::Readiness)?;
        if written == 0 {
            return Err(Refusal::Readiness);
        }
        sent += written;
    }
    let mut response = Vec::with_capacity(1024);
    let mut buffer = [0_u8; 1024];
    while response.len() < 16 * 1024 && Instant::now() < deadline {
        match pipe.read_deadline(&mut buffer, deadline) {
            Ok(0) => break,
            Ok(length) => response.extend_from_slice(&buffer[..length]),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => continue,
            Err(_) => return Err(Refusal::Readiness),
        }
        if let Some(split) = response.windows(4).position(|window| window == b"\r\n\r\n") {
            let head = std::str::from_utf8(&response[..split]).map_err(|_| Refusal::Readiness)?;
            if let Some(length) = head.lines().find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().ok())
                    .flatten()
            }) {
                if length <= 4096 && response.len() >= split + 4 + length {
                    break;
                }
            } else if response.len() > split + 4 {
                break;
            }
        }
    }
    let text = std::str::from_utf8(&response).map_err(|_| Refusal::Readiness)?;
    let (head, body) = text.split_once("\r\n\r\n").ok_or(Refusal::Readiness)?;
    if !head
        .lines()
        .next()
        .is_some_and(|line| line.starts_with("HTTP/1.") && line.contains(" 200 "))
        || body.trim() != binding.editor_commit
    {
        return Err(Refusal::Readiness);
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:security;recovery] windows-custodian-owned-worker-map
/// Only the custodian may own Worker/job handles. Its bounded per-account map
/// MUST retain live and quarantined jobs across stream loss, never evict them.
/// Replacement MUST drain all exact-job descendants to zero; accounting or
/// identity ambiguity MUST quarantine/refuse without deleting the receipt.
fn ensure_worker(runtime: &Runtime, preface: Preface, deadline: Instant) -> Result<Pipe, Refusal> {
    let binding = &preface.binding;
    let slot = runtime.workers.slot(binding.uid, || WorkerState::Empty)?;
    with_slot(&slot, deadline, |slot| {
        run_authorizer(
            Path::new(&runtime.configuration.account_authorizer),
            binding,
            deadline,
        )?;
        let identity = worker_identity(runtime, &preface)?;

        let path = receipt_path(&runtime.state, binding.uid)?;
        let account_dir = local(&format!(r"{}\u{}", runtime.state.as_str(), binding.uid))?;
        private_directory(&account_dir)?;
        match slot {
            WorkerState::QuarantinedLaunch(_job) => return Err(Refusal::Custody),
            WorkerState::Quarantined(worker) => {
                // Retain ownership even when a prior drain failed.
                let _ = worker.process_identity();
                return Err(Refusal::Custody);
            }
            WorkerState::Live(worker) => {
                if !worker.matches(&identity) {
                    return Err(Refusal::Custody);
                }
                let bytes =
                    read_private_optional(&path, RECEIPT_MAXIMUM)?.ok_or(Refusal::Custody)?;
                let receipt: Receipt =
                    serde_json::from_slice(&bytes).map_err(|_| Refusal::Custody)?;
                if !receipt_matches(&receipt, &identity, runtime)
                    || receipt.process != worker.process_identity()
                {
                    return Err(Refusal::Custody);
                }
                if held_worker_decision(worker.is_running(), || probe(worker, binding, deadline))?
                    == HeldWorkerDecision::Reuse
                {
                    return worker.connect();
                }
                if let Err(reason) = worker.terminate() {
                    let previous = std::mem::replace(slot, WorkerState::Empty);
                    if let WorkerState::Live(worker) = previous {
                        *slot = WorkerState::Quarantined(worker);
                    }
                    return Err(reason);
                }
                // Close the now-empty job before another object reuses its name.
                *slot = WorkerState::Empty;
                fs::remove_file(path.as_str()).map_err(|_| Refusal::Custody)?;
            }
            WorkerState::Empty => {
                if read_private_optional(&path, RECEIPT_MAXIMUM)?.is_some() {
                    // Custodian loss requests KILL_ON_CLOSE, but a dead root or
                    // missing job name cannot prove all descendants have exited.
                    // Without the original job handle, this account remains
                    // refused until a new MMDS physical boot namespace.
                    return Err(Refusal::Custody);
                }
            }
        }
        if Instant::now() >= deadline {
            return Err(Refusal::Readiness);
        }
        launch_and_record(runtime, identity, binding, &path, slot, deadline)?;
        match slot {
            WorkerState::Live(worker) => worker.connect(),
            _ => Err(Refusal::Custody),
        }
    })
}

fn pipe_relay(mut client: Pipe, mut worker: Pipe) -> Result<(), Refusal> {
    let mut client_writer = client.try_clone().map_err(|_| Refusal::Capacity)?;
    let mut worker_reader = worker.try_clone().map_err(|_| Refusal::Capacity)?;
    let cancelled = AtomicBool::new(false);
    thread::scope(|scope| {
        scope.spawn(|| {
            let mut bytes = [0; 65536];
            while let Ok(length) = worker_reader.read_until_cancelled(&mut bytes, &cancelled) {
                if length == 0 || client_writer.write_all(&bytes[..length]).is_err() {
                    break;
                }
            }
            cancelled.store(true, Ordering::Release);
        });
        let mut bytes = [0; 65536];
        while let Ok(length) = client.read_until_cancelled(&mut bytes, &cancelled) {
            if length == 0 || worker.write_all(&bytes[..length]).is_err() {
                break;
            }
        }
        cancelled.store(true, Ordering::Release);
    });
    Ok(())
}

fn custody_connection(mut client: Pipe, runtime: Arc<Runtime>) -> Result<(), Refusal> {
    let deadline = Instant::now() + STARTUP;
    let peer = ipc::authenticate(&mut client, true, &runtime.executable, deadline)?;
    let preface = overalls_vscode_web_broker::read_preface(&mut ipc::Deadline {
        pipe: &mut client,
        deadline,
    })?;
    validate(&preface, &runtime.boot, &runtime.descriptor)?;
    peer.verify(&runtime.executable)?;
    let worker_pipe = ensure_worker(&runtime, preface, deadline)?;
    peer.verify(&runtime.executable)?;
    ready(&mut ipc::Deadline {
        pipe: &mut client,
        deadline,
    })
    .map_err(|_| Refusal::Transport)?;
    pipe_relay(client, worker_pipe)
}

fn relay(mut client: TcpStream, mut worker: Pipe) -> Result<(), Refusal> {
    let mut client_writer = client.try_clone().map_err(|_| Refusal::Transport)?;
    let mut worker_reader = worker.try_clone().map_err(|_| Refusal::Transport)?;
    client_writer
        .set_write_timeout(Some(Duration::from_secs(30)))
        .map_err(|_| Refusal::Transport)?;
    let cancelled = AtomicBool::new(false);
    thread::scope(|scope| {
        scope.spawn(|| {
            let mut buffer = [0_u8; 64 * 1024];
            while let Ok(length) = worker_reader.read_until_cancelled(&mut buffer, &cancelled) {
                if length == 0 || client_writer.write_all(&buffer[..length]).is_err() {
                    break;
                }
            }
            cancelled.store(true, Ordering::Release);
            let _ = client_writer.shutdown(Shutdown::Both);
        });
        let _ = std::io::copy(&mut client, &mut worker);
        cancelled.store(true, Ordering::Release);
        let _ = client.shutdown(Shutdown::Both);
    });
    Ok(())
}

fn connection(mut client: TcpStream, runtime: Arc<Runtime>) -> Result<(), Refusal> {
    client
        .set_read_timeout(Some(STARTUP))
        .map_err(|_| Refusal::Transport)?;
    client
        .set_write_timeout(Some(STARTUP))
        .map_err(|_| Refusal::Transport)?;
    let deadline = Instant::now() + STARTUP;
    let preface = overalls_vscode_web_broker::read_preface(&mut client)?;
    validate(&preface, &runtime.boot, &runtime.descriptor)?;
    let mut worker = ipc::connect(&runtime.endpoint, deadline)?;
    let peer = ipc::authenticate(&mut worker, false, &runtime.executable, deadline)?;
    ipc::write_frame(
        &mut worker,
        &preface,
        overalls_vscode_web_broker::MAX_PREFACE,
        deadline,
    )?;
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Ready {
        version: u8,
        ready: bool,
    }
    let accepted: Ready = ipc::read_frame(&mut worker, 128, deadline)?;
    if accepted.version != 1 || !accepted.ready {
        return Err(Refusal::Readiness);
    }
    peer.verify(&runtime.executable)?;
    ready(&mut client).map_err(|_| Refusal::Transport)?;
    client
        .set_read_timeout(None)
        .map_err(|_| Refusal::Transport)?;
    client
        .set_write_timeout(None)
        .map_err(|_| Refusal::Transport)?;
    relay(client, worker)
}

fn serve(configuration: Configuration, custodian: bool) -> Result<(), Refusal> {
    require_system()?;
    let executable = ipc::executable()?;
    let physical = mmds::fetch(STARTUP)?;
    let node = local(&configuration.node)?;
    let server = local(&configuration.server)?;
    let system_root = local(&configuration.system_root)?;
    let ca_bundle = local(&configuration.ca_bundle)?;
    package_file(&node)?;
    package_file(&server)?;
    package_file(&ca_bundle)?;
    private_directory(&local(&configuration.state_directory)?)?;
    let namespace = local(&format!(r"{}\custodian-v1", configuration.state_directory))?;
    private_directory(&namespace)?;
    let physical_key = physical.state_key();
    let endpoint = ipc::name(physical_key)?;
    let state = local(&format!(r"{}\b{}", namespace.as_str(), physical_key))?;
    private_directory(&state)?;
    let boot = physical.boot;
    let worker_path = WorkerPath::parse(&configuration.worker_path)?;
    let runtime = Arc::new(Runtime {
        descriptor: configuration.descriptor.clone(),
        configuration,
        boot,
        package: Package {
            node,
            server,
            system_root,
            worker_path,
            extra_ca_certs: ca_bundle,
        },
        state,
        workers: CustodianAccounts::default(),
        endpoint,
        executable,
        connections: AtomicUsize::new(0),
    });
    if custodian {
        return custody_serve(runtime);
    }
    let listener =
        TcpListener::bind((runtime.boot.address, PORT)).map_err(|_| Refusal::Transport)?;
    listener
        .set_nonblocking(false)
        .map_err(|_| Refusal::Transport)?;
    event("started", None);
    for accepted in listener.incoming() {
        let client = accepted.map_err(|_| Refusal::Transport)?;
        if client.peer_addr().map_err(|_| Refusal::Transport)?.ip() != runtime.boot.gateway {
            event("refused", Some(Refusal::Transport));
            continue;
        }
        if runtime.connections.fetch_add(1, Ordering::AcqRel) >= MAX_CONNECTIONS {
            runtime.connections.fetch_sub(1, Ordering::AcqRel);
            event("refused", Some(Refusal::Capacity));
            continue;
        }
        let runtime = runtime.clone();
        thread::spawn(move || {
            let result = connection(client, runtime.clone());
            runtime.connections.fetch_sub(1, Ordering::AcqRel);
            if let Err(reason) = result {
                event("refused", Some(reason));
            }
        });
    }
    Err(Refusal::Transport)
}

fn custody_serve(runtime: Arc<Runtime>) -> Result<(), Refusal> {
    // Reserve the first instance before admitting any request. Create its
    // successor while the accepted instance remains owned, so the name never
    // becomes available for another server between connections.
    let mut listener = ipc::listener(&runtime.endpoint, true)?;
    event("started", None);
    loop {
        listener.accept().map_err(|_| Refusal::Transport)?;
        let next = loop {
            match ipc::listener(&runtime.endpoint, false) {
                Ok(next) => break next,
                // Keep the accepted instance/name and every worker intact while
                // the fixed pipe budget is full. Callers retain startup deadlines.
                Err(Refusal::Capacity) => thread::sleep(Duration::from_millis(50)),
                Err(reason) => return Err(reason),
            }
        };
        let client = std::mem::replace(&mut listener, next);
        if runtime.connections.fetch_add(1, Ordering::AcqRel) >= MAX_CONNECTIONS {
            runtime.connections.fetch_sub(1, Ordering::AcqRel);
            event("refused", Some(Refusal::Capacity));
            continue;
        }
        let runtime = runtime.clone();
        thread::spawn(move || {
            let result = custody_connection(client, runtime.clone());
            runtime.connections.fetch_sub(1, Ordering::AcqRel);
            if let Err(reason) = result {
                event("refused", Some(reason));
            }
        });
    }
}

pub(crate) fn main() -> std::process::ExitCode {
    let mut arguments = std::env::args_os().skip(1);
    let first = arguments.next();
    let custodian = first.as_deref() == Some(std::ffi::OsStr::new("--custodian"));
    let path = if custodian { arguments.next() } else { first };
    let Some(path) = path else {
        event("failed", Some(Refusal::Package));
        return std::process::ExitCode::FAILURE;
    };
    if arguments.next().is_some() {
        event("failed", Some(Refusal::Package));
        return std::process::ExitCode::FAILURE;
    }
    match read_configuration(Path::new(&path))
        .and_then(|configuration| serve(configuration, custodian))
    {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(reason) => {
            event("failed", Some(reason));
            std::process::ExitCode::FAILURE
        }
    }
}

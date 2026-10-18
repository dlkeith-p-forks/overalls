//! Windows guest editor broker.
//!
//! This process is a SYSTEM-owned gateway.  It obtains the physical boot
//! identity from MMDS, admits Lilly's closed preface, reconciles the account
//! through Lyra, and only then opens the exact retained Code OSS worker pipe.
//! The implementation deliberately keeps the Windows listener separate from
//! the Linux systemd broker; no Windows image is editor-capable until its
//! package and manifest promote this code.

use overalls_vscode_web_broker::windows::{
    Package, Worker, package_file, private_directory, read_private_optional, require_system,
    resolve_account, write_private,
};
use overalls_vscode_web_broker::windows_model::{ProcessIdentity, WorkerIdentity};
use overalls_vscode_web_broker::windows_pipe::Pipe;
use overalls_vscode_web_broker::{
    Binding, Boot, Descriptor, PORT, Preface, Refusal, mmds, ready, validate,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::net::{Shutdown, TcpListener, TcpStream};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const STARTUP: Duration = Duration::from_secs(20);
const MAX_CONNECTIONS: usize = 64;
const MAX_ACCOUNTS: usize = 512;
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
    binding: Binding,
    process: ProcessIdentity,
}

struct Runtime {
    configuration: Configuration,
    descriptor: Descriptor,
    boot: Boot,
    package: Package,
    state: overalls_vscode_web_broker::windows_model::LocalPath,
    locks: Mutex<BTreeMap<u32, Arc<Mutex<()>>>>,
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

fn lock_for(runtime: &Runtime, uid: u32, deadline: Instant) -> Result<Arc<Mutex<()>>, Refusal> {
    let mut locks = runtime.locks.lock().map_err(|_| Refusal::Capacity)?;
    if !locks.contains_key(&uid) && locks.len() >= MAX_ACCOUNTS {
        return Err(Refusal::Capacity);
    }
    let lock = locks.entry(uid).or_default().clone();
    drop(locks);
    while Instant::now() < deadline {
        let acquired = match lock.try_lock() {
            Ok(guard) => {
                drop(guard);
                true
            }
            Err(_) => false,
        };
        if acquired {
            return Ok(lock);
        }
        thread::sleep(Duration::from_millis(10));
    }
    Err(Refusal::Startup)
}

fn with_lock<T>(
    lock: &Arc<Mutex<()>>,
    deadline: Instant,
    operation: impl FnOnce() -> Result<T, Refusal>,
) -> Result<T, Refusal> {
    while Instant::now() < deadline {
        if let Ok(guard) = lock.try_lock() {
            let result = operation();
            drop(guard);
            return result;
        }
        thread::sleep(Duration::from_millis(10));
    }
    Err(Refusal::Startup)
}

fn worker_identity(runtime: &Runtime, preface: &Preface) -> Result<WorkerIdentity, Refusal> {
    let sid = resolve_account(preface.binding.uid, &preface.binding.username)?;
    WorkerIdentity::admitted(preface, &runtime.boot, &runtime.descriptor, sid)
}

fn receipt_matches(receipt: &Receipt, binding: &Binding, descriptor: &Descriptor) -> bool {
    receipt.binding == *binding
        && receipt.binding.editor_protocol == descriptor.protocol
        && receipt.binding.editor_commit == descriptor.commit
        && receipt.binding.editor_release == descriptor.release
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

fn ensure_worker(
    runtime: &Runtime,
    preface: Preface,
    deadline: Instant,
) -> Result<Worker, Refusal> {
    let binding = &preface.binding;
    run_authorizer(
        Path::new(&runtime.configuration.account_authorizer),
        binding,
        deadline,
    )?;
    let identity = worker_identity(runtime, &preface)?;
    let receipt_path = receipt_path(&runtime.state, binding.uid)?;
    let account_dir = local(&format!(r"{}\u{}", runtime.state.as_str(), binding.uid))?;
    private_directory(&account_dir)?;
    if let Some(bytes) = read_private_optional(&receipt_path, RECEIPT_MAXIMUM)? {
        let receipt: Receipt = serde_json::from_slice(&bytes).map_err(|_| Refusal::Custody)?;
        if !receipt_matches(&receipt, binding, &runtime.descriptor) {
            return Err(Refusal::Custody);
        }
        let worker = match Worker::recover(
            identity.clone(),
            receipt.process,
            local(&runtime.configuration.node)?,
        )? {
            Some(worker) => worker,
            None => {
                fs::remove_file(receipt_path.as_str()).map_err(|_| Refusal::Custody)?;
                let worker = Worker::launch(identity.clone(), &runtime.package)?;
                let receipt = Receipt {
                    binding: binding.clone(),
                    process: worker.process_identity(),
                };
                let encoded = serde_json::to_vec(&receipt).map_err(|_| Refusal::Custody)?;
                if let Err(error) = write_private(&receipt_path, &encoded) {
                    let _ = worker.terminate();
                    return Err(error);
                }
                worker
            }
        };
        if probe(&worker, binding, deadline).is_ok() {
            return Ok(worker);
        }
        if !worker.is_running()? {
            fs::remove_file(receipt_path.as_str()).map_err(|_| Refusal::Custody)?;
        } else {
            worker.terminate()?;
            fs::remove_file(receipt_path.as_str()).map_err(|_| Refusal::Custody)?;
        }
        let worker = Worker::launch(identity.clone(), &runtime.package)?;
        let receipt = Receipt {
            binding: binding.clone(),
            process: worker.process_identity(),
        };
        write_private(
            &receipt_path,
            &serde_json::to_vec(&receipt).map_err(|_| Refusal::Custody)?,
        )?;
        let mut ready = false;
        while Instant::now() < deadline {
            if probe(&worker, binding, deadline).is_ok() {
                ready = true;
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        if ready {
            return Ok(worker);
        }
        worker.terminate()?;
        fs::remove_file(receipt_path.as_str()).map_err(|_| Refusal::Custody)?;
        return Err(Refusal::Readiness);
    }
    let worker = Worker::launch(identity, &runtime.package)?;
    let receipt = Receipt {
        binding: binding.clone(),
        process: worker.process_identity(),
    };
    let encoded = serde_json::to_vec(&receipt).map_err(|_| Refusal::Custody)?;
    write_private(&receipt_path, &encoded)?;
    let mut ready = false;
    while Instant::now() < deadline {
        if probe(&worker, binding, deadline).is_ok() {
            ready = true;
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    if ready {
        Ok(worker)
    } else {
        worker.terminate()?;
        fs::remove_file(receipt_path.as_str()).map_err(|_| Refusal::Custody)?;
        Err(Refusal::Readiness)
    }
}

fn relay(mut client: TcpStream, mut worker: Pipe) -> Result<(), Refusal> {
    let mut client_writer = client.try_clone().map_err(|_| Refusal::Transport)?;
    let mut worker_reader = worker.try_clone().map_err(|_| Refusal::Transport)?;
    thread::scope(|scope| {
        scope.spawn(|| {
            let _ = std::io::copy(&mut worker_reader, &mut client_writer);
            let _ = client_writer.shutdown(Shutdown::Both);
        });
        let _ = std::io::copy(&mut client, &mut worker);
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
    let lock = lock_for(&runtime, preface.binding.uid, deadline)?;
    let worker = with_lock(&lock, deadline, || {
        ensure_worker(&runtime, preface, deadline)
    })?;
    ready(&mut client).map_err(|_| Refusal::Transport)?;
    client
        .set_read_timeout(None)
        .map_err(|_| Refusal::Transport)?;
    client
        .set_write_timeout(None)
        .map_err(|_| Refusal::Transport)?;
    relay(client, worker.connect()?)
}

fn serve(configuration: Configuration) -> Result<(), Refusal> {
    require_system()?;
    let boot = mmds::fetch(STARTUP)?;
    let node = local(&configuration.node)?;
    let server = local(&configuration.server)?;
    let system_root = local(&configuration.system_root)?;
    let ca_bundle = local(&configuration.ca_bundle)?;
    package_file(&node)?;
    package_file(&server)?;
    package_file(&ca_bundle)?;
    private_directory(&local(&configuration.state_directory)?)?;
    let state = local(&configuration.state_directory)?;
    let worker_path = configuration.worker_path.clone();
    let listener = TcpListener::bind((boot.address, PORT)).map_err(|_| Refusal::Transport)?;
    listener
        .set_nonblocking(false)
        .map_err(|_| Refusal::Transport)?;
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
        locks: Mutex::new(BTreeMap::new()),
        connections: AtomicUsize::new(0),
    });
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

pub(crate) fn main() -> std::process::ExitCode {
    let mut arguments = std::env::args_os().skip(1);
    let Some(path) = arguments.next() else {
        event("failed", Some(Refusal::Package));
        return std::process::ExitCode::FAILURE;
    };
    if arguments.next().is_some() {
        event("failed", Some(Refusal::Package));
        return std::process::ExitCode::FAILURE;
    }
    match read_configuration(Path::new(&path)).and_then(serve) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(reason) => {
            event("failed", Some(reason));
            std::process::ExitCode::FAILURE
        }
    }
}

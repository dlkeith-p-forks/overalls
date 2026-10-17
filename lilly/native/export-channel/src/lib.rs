#![deny(unsafe_code)]
#![doc = "Non-setuid local export channel. Data FD and completion channel stay separate."]

use rustix::event::{PollFd, PollFlags};
use rustix::io::Errno;
use rustix::net::sockopt::{set_socket_timeout, socket_peercred, Timeout};
use rustix::net::{
    recvmsg, sendmsg, RecvAncillaryBuffer, RecvAncillaryMessage, RecvFlags, ReturnFlags,
    SendAncillaryBuffer, SendAncillaryMessage, SendFlags,
};
use rustix::process::{getpid, kill_process, kill_process_group, set_child_subreaper};
use rustix::process::{waitid, Pid, Signal, WaitId, WaitIdOptions};
use std::ffi::{OsStr, OsString};
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::os::unix::process::CommandExt as _;
use std::path::PathBuf;
use std::process::{Command as Process, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

pub const EXIT_USAGE: u8 = 64;
pub const EXIT_FAILED: u8 = 1;

/// One authenticated export request: exactly one 8456-byte record plus an
/// SCM_RIGHTS descriptor on any path.
pub const MAGIC: &[u8; 4] = b"LEX3";
pub const KEY_BYTES: usize = 128;
pub const COMMAND_BYTES: usize = 8320;
pub const WIRE_BYTES: usize = MAGIC.len() + 2 + 2 + KEY_BYTES + COMMAND_BYTES;

static CANCELLED: AtomicBool = AtomicBool::new(false);

extern "C" fn cancel_handler(_signal: libc::c_int) {
    CANCELLED.store(true, Ordering::Relaxed);
}

/// @cc [owner:ghuntley,label:recovery] export-cancel-signal-shim
/// TERM/INT registration via libc is unsafe-signatured; the handler records
/// an atomic flag and nothing else. No data crosses the boundary.
pub fn install_cancel_handlers() {
    #[allow(unsafe_code)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        libc::signal(
            libc::SIGTERM,
            cancel_handler as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            cancel_handler as *const () as libc::sighandler_t,
        );
    }
}

pub fn cancelled() -> bool {
    CANCELLED.load(Ordering::Relaxed)
}

/// The wire-visible export request.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Request {
    pub key: String,
    pub command: String,
}

fn key_bytes_ok(bytes: &[u8]) -> bool {
    bytes
        .iter()
        .all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(b))
}

fn command_ok(bytes: &[u8]) -> bool {
    !bytes.is_empty() && bytes.len() < COMMAND_BYTES && bytes.iter().all(|b| (32..=126).contains(b))
}

/// @cc [owner:ghuntley,label:protocol] export-record-exact-fields
/// Records MUST have exactly one 68-byte charset key, one nonempty bounded
/// printable command, and zero-filled padding; anything else MUST be rejected
/// before the worker environment is prepared.
pub fn build(key: &str, command: &str) -> Option<Request> {
    if key.len() != 68 || !key_bytes_ok(key.as_bytes()) {
        return None;
    }
    if !command_ok(command.as_bytes()) {
        return None;
    }
    Some(Request {
        key: key.to_string(),
        command: command.to_string(),
    })
}

pub fn encode(request: &Request) -> [u8; WIRE_BYTES] {
    debug_assert_eq!(request.key.len(), 68);
    let mut wire = [0_u8; WIRE_BYTES];
    wire[0..4].copy_from_slice(MAGIC);
    wire[4..6].copy_from_slice(&68_u16.to_be_bytes());
    wire[6..8].copy_from_slice(&(request.command.len() as u16).to_be_bytes());
    wire[8..8 + 68].copy_from_slice(request.key.as_bytes());
    let start = 8 + KEY_BYTES;
    wire[start..start + request.command.len()].copy_from_slice(request.command.as_bytes());
    wire
}

pub fn decode(wire: &[u8]) -> Option<Request> {
    if wire.len() != WIRE_BYTES {
        return None;
    }
    if &wire[0..4] != MAGIC {
        return None;
    }
    let key_size = u16::from_be_bytes([wire[4], wire[5]]);
    let command_size = u16::from_be_bytes([wire[6], wire[7]]);
    if key_size as usize != 68 || command_size == 0 || command_size as usize >= COMMAND_BYTES {
        return None;
    }
    let key = &wire[8..8 + KEY_BYTES];
    let command = &wire[8 + KEY_BYTES..];
    if !key[..key_size as usize]
        .iter()
        .all(|b| key_bytes_ok([*b].as_slice()) && *b != 0)
    {
        return None;
    }
    if !command[..command_size as usize]
        .iter()
        .all(|byte| (32..=126).contains(byte))
    {
        return None;
    }
    if key[key_size as usize..].iter().any(|b| *b != 0)
        || command[command_size as usize..].iter().any(|b| *b != 0)
    {
        return None;
    }
    Some(Request {
        key: String::from_utf8(key[..68].to_vec()).expect("charset is ASCII-safe"),
        command: String::from_utf8(command[..command_size as usize].to_vec())
            .expect("printable ASCII"),
    })
}

/// Validated bridge invocation: absolute socket path plus key; the SSH-side
/// command arrives through SSH_ORIGINAL_COMMAND only.
#[derive(Debug, Eq, PartialEq)]
pub struct BridgeRequest {
    pub socket: PathBuf,
    pub key: String,
    pub command: String,
}

pub fn parse_bridge(
    arguments: &[OsString],
    original_command: Option<&OsStr>,
) -> Option<BridgeRequest> {
    let [socket, key] = arguments else {
        return None;
    };
    if !socket.as_os_str().as_bytes().starts_with(b"/") {
        return None;
    }
    let key = key.to_str()?;
    let command = original_command?.to_str()?;
    let request = build(key, command)?;
    Some(BridgeRequest {
        socket: PathBuf::from(socket),
        key: request.key,
        command: request.command,
    })
}

/// Validated serve invocation: a trusted account name and fixed worker argv.
#[derive(Debug, Eq, PartialEq)]
pub struct ServeRequest {
    pub account: String,
    pub worker: Vec<OsString>,
}

pub fn parse_serve(arguments: &[OsString]) -> Option<ServeRequest> {
    if arguments.len() < 2 || arguments.len() > 31 {
        return None;
    }
    let account = arguments[0].to_str()?;
    let worker = &arguments[1..];
    if worker.is_empty() || !worker[0].as_os_str().as_bytes().starts_with(b"/") {
        return None;
    }
    Some(ServeRequest {
        account: account.to_string(),
        worker: worker.to_vec(),
    })
}

// -- Bridge side. --

/// @cc [owner:ghuntley,label:security] export-channel-authenticated-descriptor
/// The bridge runs only as the dedicated SSH account with a server-selected key
/// argv. It sends one bounded request + inherited stdout descriptor to the
/// configured local socket, verifies the server matches that socket's owner,
/// and reports success only from the separate completion byte.
pub fn bridge(request: &BridgeRequest) -> u8 {
    install_cancel_handlers();
    let metadata = match std::fs::symlink_metadata(&request.socket) {
        Err(_) => return EXIT_FAILED,
        Ok(metadata) => metadata,
    };
    if !metadata.file_type().is_socket() {
        return EXIT_FAILED;
    }
    let socket = match rustix::net::socket_with(
        rustix::net::AddressFamily::UNIX,
        rustix::net::SocketType::STREAM,
        rustix::net::SocketFlags::CLOEXEC | rustix::net::SocketFlags::NONBLOCK,
        None,
    ) {
        Err(_) => return EXIT_FAILED,
        Ok(fd) => fd,
    };
    let address = match rustix::net::SocketAddrUnix::new(&request.socket) {
        Err(_) => return EXIT_FAILED,
        Ok(addr) => addr,
    };
    // A nonblocking stream connect returns at once for local listeners;
    // anything that comes back is a refused boundary, matching C's `||` shape.
    if rustix::net::connect(&socket, &address).is_err() {
        return EXIT_FAILED;
    }
    let creds = match socket_peercred(&socket) {
        Err(_) => return EXIT_FAILED,
        Ok(creds) => creds,
    };
    if creds.uid.as_raw() != metadata.uid() {
        return EXIT_FAILED;
    }
    let wire = encode(&Request {
        key: request.key.clone(),
        command: request.command.clone(),
    });
    let mut space = [std::mem::MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(1))];
    let mut ancillary = SendAncillaryBuffer::new(&mut space);
    let stdout_fd = std::io::stdout();
    let stdout_borrow = stdout_fd.as_fd();
    let rights = [stdout_borrow];
    if !ancillary.push(SendAncillaryMessage::ScmRights(&rights)) {
        return EXIT_FAILED;
    }
    match sendmsg(
        &socket,
        &[std::io::IoSlice::new(&wire)],
        &mut ancillary,
        SendFlags::NOSIGNAL,
    ) {
        Ok(sent) if sent == WIRE_BYTES => {}
        Ok(_) => return EXIT_FAILED,
        Err(_) => return EXIT_FAILED,
    }
    bridge_await(socket.as_fd())
}

fn bridge_await(socket: BorrowedFd<'_>) -> u8 {
    loop {
        if cancelled() {
            return EXIT_FAILED;
        }
        let mut fds = [PollFd::from_borrowed_fd(
            socket,
            PollFlags::IN | PollFlags::HUP,
        )];
        match rustix::event::poll(
            &mut fds,
            Some(&rustix::event::Timespec {
                tv_sec: 0,
                tv_nsec: 100_000_000,
            }),
        ) {
            Err(Errno::INTR) => continue,
            Err(_) => return EXIT_FAILED,
            Ok(_) => {}
        }
        if fds[0].revents().is_empty() {
            continue;
        }
        let mut status = [0_u8; 1];
        match rustix::net::recv(socket, &mut status, RecvFlags::empty()) {
            Ok((1, _)) => return if status[0] == 0 { 0 } else { EXIT_FAILED },
            _ => return EXIT_FAILED,
        }
    }
}

// -- Serve side. --

#[allow(unsafe_code)]
mod posix {
    /// getpwnam returns shared storage; the shim reads pw_uid immediately and
    /// forgets the pointer.
    pub(super) fn account_uid(name: &str) -> Option<u32> {
        let name = std::ffi::CString::new(name).ok()?;
        let entry = unsafe { libc::getpwnam(name.as_ptr()) };
        if entry.is_null() {
            None
        } else {
            Some(unsafe { *entry }.pw_uid)
        }
    }
}

/// @cc [owner:ghuntley,label:security;recovery] export-channel-private-service-boundary
/// serve requires a root-owned systemd socket restricted to the dedicated
/// transfer account, a trusted account name and fixed worker argv. Peer creds
/// are verified; one writable FD + bounded frame; only the selected key/request
/// reach the fixed worker environment. The worker MUST recheck native permit
/// authority. Disconnect cancels the worker. Completion waits for reaping; data
/// EOF or a disconnected requester never confirm successful export or
/// quiescence.
pub fn serve(request: &ServeRequest, channel: BorrowedFd<'_>) -> u8 {
    install_cancel_handlers();
    let Some(account_uid) = posix::account_uid(&request.account) else {
        return EXIT_FAILED;
    };
    let creds = match socket_peercred(channel) {
        Err(_) => return EXIT_FAILED,
        Ok(creds) => creds,
    };
    if creds.uid.as_raw() != account_uid {
        return EXIT_FAILED;
    }
    if set_child_subreaper(Some(getpid())).is_err() {
        return EXIT_FAILED;
    }
    if set_socket_timeout(channel, Timeout::Recv, Some(Duration::from_secs(5))).is_err() {
        return EXIT_FAILED;
    }
    let mut wire = [0_u8; WIRE_BYTES];
    let mut space = [std::mem::MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(1))];
    let mut ancillary = RecvAncillaryBuffer::new(&mut space);
    let received: Option<OwnedFd> = (|| {
        let outcome = recvmsg(
            channel,
            &mut [std::io::IoSliceMut::new(&mut wire)],
            &mut ancillary,
            RecvFlags::WAITALL | RecvFlags::CMSG_CLOEXEC,
        )
        .ok()?;
        if outcome.bytes != WIRE_BYTES
            || outcome
                .flags
                .contains(ReturnFlags::TRUNC | ReturnFlags::CTRUNC)
        {
            return None;
        }
        let mut received: Option<OwnedFd> = None;
        for message in ancillary.drain() {
            if let RecvAncillaryMessage::ScmRights(fds) = message {
                let mut fds = fds;
                if received.is_some() || fds.len() != 1 {
                    return None;
                }
                received = fds.next();
            }
        }
        received
    })();
    let Some(received) = received else {
        return EXIT_FAILED;
    };
    if cancelled() {
        return EXIT_FAILED;
    }
    let Some(record) = decode(&wire) else {
        return EXIT_FAILED;
    };
    let mode = match rustix::fs::fcntl_getfl(&received) {
        Err(_) => return EXIT_FAILED,
        Ok(flags) => flags,
    };
    if mode & rustix::fs::OFlags::ACCMODE == rustix::fs::OFlags::RDONLY {
        return EXIT_FAILED;
    }
    serve_worker(request, &record, &received, channel)
}

fn serve_worker(
    request: &ServeRequest,
    record: &Request,
    received: &OwnedFd,
    channel: BorrowedFd<'_>,
) -> u8 {
    let forwarded = std::fs::File::from(
        received
            .try_clone()
            .expect("duplicate the received descriptor"),
    );
    let mut builder = Process::new(&request.worker[0]);
    builder
        .args(&request.worker[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::from(forwarded))
        .stderr(Stdio::inherit())
        .env("LILLY_EXPORT_KEY", &record.key)
        .env("LILLY_EXPORT_REQUEST", &record.command);
    builder.process_group(0);
    pins::serve_child(&mut builder, getpid());
    let mut worker = match builder.spawn() {
        Err(_) => return EXIT_FAILED,
        Ok(worker) => worker,
    };
    let mut status = 1_u8;
    loop {
        if cancelled() {
            break;
        }
        match child_status(&worker) {
            Err(()) => break,
            Ok(Some(ok)) => {
                status = if ok { 0 } else { 1 };
                break;
            }
            Ok(None) => {}
        }
        let mut fds = [PollFd::from_borrowed_fd(
            channel,
            PollFlags::IN | PollFlags::HUP,
        )];
        match rustix::event::poll(
            &mut fds,
            Some(&rustix::event::Timespec {
                tv_sec: 0,
                tv_nsec: 25_000_000,
            }),
        ) {
            Err(Errno::INTR) => continue,
            Err(_) => break,
            Ok(_) => {}
        }
        if !fds[0].revents().is_empty() {
            break;
        }
    }
    // Completion is confirmed only after reaping: data EOF or a disconnected
    // requester never confirmed successful export.
    finish(&mut worker);
    match rustix::net::send(channel, &[status], SendFlags::NOSIGNAL) {
        Ok(1) => status,
        _ => EXIT_FAILED,
    }
}

fn child_status(child: &std::process::Child) -> Result<Option<bool>, ()> {
    let pid = Pid::from_raw(child.id() as i32).ok_or(())?;
    match waitid(
        WaitId::Pid(pid),
        WaitIdOptions::EXITED | WaitIdOptions::NOHANG | WaitIdOptions::NOWAIT,
    ) {
        Err(_) => Err(()),
        Ok(None) => Ok(None),
        Ok(Some(status)) => Ok(Some(status.exited() && status.exit_status() == Some(0))),
    }
}

#[allow(unsafe_code)]
mod pins {
    use rustix::process::{getppid, set_parent_process_death_signal, Pid, Signal};
    use std::os::unix::process::CommandExt;
    use std::process::Command;

    /// @cc [owner:ghuntley,label:security] serve-child-pins-and-purges
    /// The fixed worker resets dispositions and gains a parent-death fence;
    /// every other descriptor the helper owns either is CLOEXEC'd at receipt
    /// time or arrives through the std Stdio mapping only. Unsafe-declared
    /// calls stay confined to this hook.
    pub(super) fn serve_child(command: &mut Command, parent: Pid) {
        unsafe {
            command.pre_exec(move || {
                if set_parent_process_death_signal(Some(Signal::KILL)).is_err()
                    || getppid() != Some(parent)
                {
                    return Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied));
                }
                libc::signal(libc::SIGTERM, libc::SIG_DFL);
                libc::signal(libc::SIGINT, libc::SIG_DFL);
                libc::signal(libc::SIGPIPE, libc::SIG_DFL);
                Ok(())
            })
        };
    }
}

fn finish(worker: &mut std::process::Child) {
    if let Some(pid) = Pid::from_raw(worker.id() as i32) {
        let _ = kill_process_group(pid, Signal::KILL);
        let _ = kill_process(pid, Signal::KILL);
    }
    let _ = worker.wait();
    loop {
        match waitid(WaitId::All, WaitIdOptions::EXITED) {
            Err(_) => return,
            Ok(None) => return,
            Ok(Some(_)) => continue,
        }
    }
}

#[cfg(test)]
mod tests;

#![deny(unsafe_code)]
#![doc = "Non-setuid ZFS exporter. FD 3/4 carry private control; stdout carries disk bytes."]

use rustix::event::{PollFd, PollFlags};
use rustix::fs::{flock, open, FlockOperation, Mode as FileMode, OFlags};
use rustix::io::Errno;
use rustix::pipe::{pipe_with, PipeFlags};
use rustix::process::{
    getpid, kill_process_group, wait, waitid, Pid, Signal, WaitId, WaitIdOptions, WaitOptions,
};
use std::ffi::{OsStr, OsString};
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::CommandExt as _;
use std::path::{Path, PathBuf};
use std::process::{Command as Process, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// Startup control line and main-loop renewals are bounded to 128 bytes.
pub const CONTROL_FRAME_LIMIT: usize = 128;
/// Diagnostics are discarded with this bound.
pub const DIAGNOSTICS_LIMIT: usize = 65536;
/// argv sizing bound inherited from the C protocol.
pub const ARGV_TOTAL_LIMIT: usize = 65536;
pub const MAX_ARGV: usize = 128;

pub const EXIT_USAGE: u8 = 64;
pub const EXIT_SETUP: u8 = 70;
pub const EXIT_SENDER_FAILED: u8 = 1;
pub const EXIT_DEADLINE: u8 = 2;
pub const EXIT_DIAGNOSTICS: u8 = 3;
pub const EXIT_REVOKED: u8 = 4;
pub const EXIT_INSECURE_LOCK: u8 = 73;
pub const EXIT_IO: u8 = 74;

static CANCELLED: AtomicBool = AtomicBool::new(false);

extern "C" fn cancel_handler(_signal: libc::c_int) {
    CANCELLED.store(true, Ordering::Relaxed);
}

/// @cc [owner:ghuntley,label:recovery] source-export-signal-shim
/// The TERM/INT cancellation handler only records into an atomic flag read by
/// the lease loop; libc's signal registration is unsafe-signatured, so this is
/// the entire confinement surface. No data, sender pid or path crosses it.
pub fn install_cancel_handlers() {
    install_cancel_handlers_impl()
}

#[allow(unsafe_code)]
fn install_cancel_handlers_impl() {
    // signal() with a plain extern-C handler storing an AtomicBool is
    // async-signal-safe and bounded; no relocking, allocation or IO.
    let lock = unsafe {
        libc::signal(
            libc::SIGTERM,
            cancel_handler as *const () as libc::sighandler_t,
        )
    };
    let _ = lock;
    let ignore = unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
    let _ = ignore;
    let cancel = unsafe {
        libc::signal(
            libc::SIGINT,
            cancel_handler as *const () as libc::sighandler_t,
        )
    };
    let _ = cancel;
}

/// A validated invocation: private lock path, bounded lease, trusted sender argv.
#[derive(Debug, Eq, PartialEq)]
pub struct Request {
    pub lock: PathBuf,
    pub lease_ms: u32,
    pub sender: PathBuf,
    pub arguments: Vec<OsString>,
}

fn duration(text: &OsStr) -> Option<u32> {
    let bytes = text.as_bytes();
    if bytes.is_empty() || bytes[0] == b'0' || !bytes.iter().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    let value: u32 = text.parse().ok()?;
    (1..=300_000).contains(&value).then_some(value)
}

pub fn parse_cli(arguments: &[OsString]) -> Option<Request> {
    let [lock, lease_text, sender, rest @ ..] = arguments else {
        return None;
    };
    if arguments.len() > MAX_ARGV + 2 {
        return None;
    }
    for absolute in [lock, sender] {
        if !absolute.as_os_str().as_bytes().starts_with(b"/") {
            return None;
        }
    }
    // The C byte span covers the sender and its arguments only.
    let total: usize = arguments[2..]
        .iter()
        .map(|arg| arg.as_os_str().as_bytes().len() + 1)
        .sum();
    if total > ARGV_TOTAL_LIMIT {
        return None;
    }
    Some(Request {
        lock: PathBuf::from(lock),
        lease_ms: duration(lease_text)?,
        sender: PathBuf::from(sender),
        arguments: rest.to_vec(),
    })
}

/// One received control frame.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Control {
    Renew(u32),
    Revoke,
}

/// Parse a main-loop frame: `L<millis>` renews, `X` (and any other content)
/// revokes per the wire contract.
pub fn parse_control(frame: &[u8]) -> Option<Control> {
    match frame {
        [b'L', rest @ ..] => {
            let text = std::str::from_utf8(rest).ok()?;
            let value = duration(OsStr::new(text))?;
            Some(Control::Renew(value))
        }
        _ => None,
    }
}

/// The lock-file custody check for the sender's private boundary. Returns a
/// held exclusive lock on success.
fn acquire_lock(path: &Path) -> Result<Held, u8> {
    let descriptor = open(
        path,
        OFlags::RDWR | OFlags::CREATE | OFlags::NOFOLLOW,
        FileMode::from_raw_mode(0o600),
    )
    .map_err(|_| EXIT_INSECURE_LOCK)?;
    let file: std::fs::File = descriptor.into();
    let metadata = file.metadata().map_err(|_| EXIT_INSECURE_LOCK)?;
    {
        use std::os::unix::fs::MetadataExt as _;
        let private = metadata.is_file()
            && metadata.nlink() == 1
            && metadata.uid() == rustix::process::geteuid().as_raw()
            && metadata.mode() & 0o022 == 0;
        if !private {
            return Err(EXIT_INSECURE_LOCK);
        }
    }
    let fd: OwnedFd = file.into();
    flock(&fd, FlockOperation::NonBlockingLockExclusive).map_err(|_| EXIT_INSECURE_LOCK)?;
    if rustix::fs::fchmod(&fd, FileMode::from_raw_mode(0o600)).is_err() {
        return Err(EXIT_INSECURE_LOCK);
    }
    Ok(Held { descriptor: fd })
}

/// The custody-owned lock for the sweep's duration.
pub struct Held {
    #[allow(dead_code)]
    descriptor: OwnedFd,
}

fn write_all(fd: BorrowedFd<'_>, mut buffer: &[u8]) -> Result<(), ()> {
    while !buffer.is_empty() {
        match rustix::io::write(fd, buffer) {
            Err(Errno::INTR) => continue,
            Err(_) | Ok(0) => return Err(()),
            Ok(count) => buffer = &buffer[count..],
        }
    }
    Ok(())
}

/// The Erlang port ABI (`:nouse_stdio`) places the control channel at fd 3
/// and the acknowledgement channel at fd 4 of the spawned child. Borrowing
/// the two fixed numbers is the entire unsafe surface; nothing beyond file
/// descriptor identity crosses it.
#[allow(unsafe_code)]
mod fd_abi {
    use std::os::fd::BorrowedFd;

    pub(super) fn control() -> BorrowedFd<'static> {
        unsafe { BorrowedFd::borrow_raw(3) }
    }

    pub(super) fn ack() -> BorrowedFd<'static> {
        unsafe { BorrowedFd::borrow_raw(4) }
    }
}

pub fn run(request: &Request) -> u8 {
    // The entry points close the attacker-inherited window: f3/f4 must never
    // ride into the sender.
    let control = fd_abi::control();
    let ack = fd_abi::ack();
    install_cancel_handlers();
    // Sender's descendants reparent here for reaping before ownership releases.
    if rustix::process::set_child_subreaper(Some(getpid())).is_err() {
        return EXIT_SETUP;
    }
    if rustix::io::fcntl_setfd(control, rustix::io::FdFlags::CLOEXEC).is_err()
        || rustix::io::fcntl_setfd(ack, rustix::io::FdFlags::CLOEXEC).is_err()
    {
        return EXIT_SETUP;
    }
    let mut deadline = Instant::now() + Duration::from_millis(u64::from(request.lease_ms));
    // Startup phase: exactly one bounded control line before ownership.
    let mut frame: Vec<u8> = Vec::with_capacity(CONTROL_FRAME_LIMIT);
    loop {
        if CANCELLED.load(Ordering::Relaxed) || Instant::now() >= deadline {
            return EXIT_REVOKED;
        }
        match rustix::event::poll(
            &mut [PollFd::from_borrowed_fd(
                control,
                PollFlags::IN | PollFlags::HUP,
            )],
            Some(&rustix::event::Timespec {
                tv_sec: 0,
                tv_nsec: 50_000_000,
            }),
        ) {
            Err(Errno::INTR) => continue,
            Err(_) => return EXIT_IO,
            Ok(0) => continue,
            Ok(_) => {}
        }
        let mut byte = [0_u8; 1];
        match rustix::io::read(control, &mut byte) {
            Err(_) | Ok(0) => return EXIT_IO,
            Ok(_) => {}
        }
        if frame.len() >= CONTROL_FRAME_LIMIT {
            return EXIT_IO;
        }
        frame.push(byte[0]);
        if byte[0] == b'\n' {
            break;
        }
    }
    let _held = match acquire_lock(&request.lock) {
        Err(code) => return code,
        Ok(held) => held,
    };
    run_sender(request, control, ack, &mut deadline, &frame)
}

fn run_sender(
    request: &Request,
    control: BorrowedFd<'_>,
    ack: BorrowedFd<'_>,
    deadline: &mut Instant,
    startup_frame: &[u8],
) -> u8 {
    let (diag_read, diag_write) = match pipe_with(PipeFlags::CLOEXEC) {
        Err(_) => return EXIT_SETUP,
        Ok(pair) => pair,
    };
    if rustix::fs::fcntl_setfl(&diag_read, OFlags::NONBLOCK).is_err() {
        return EXIT_SETUP;
    }
    let mut child = match spawn_sender(request, diag_write) {
        Err(_) => return EXIT_SETUP,
        Ok(child) => child,
    };
    let Some(sender_pid) = i32::try_from(child.id()).ok().and_then(Pid::from_raw) else {
        return finish(&mut child, EXIT_SETUP);
    };
    if write_all(ack, startup_frame).is_err() {
        return finish(&mut child, EXIT_REVOKED);
    }
    if rustix::fs::fcntl_setfl(control, OFlags::NONBLOCK).is_err() {
        return finish(&mut child, EXIT_SETUP);
    }
    let mut frame: Vec<u8> = Vec::with_capacity(CONTROL_FRAME_LIMIT);
    let mut diagnostics_total = 0_usize;
    loop {
        if CANCELLED.load(Ordering::Relaxed) {
            return finish(&mut child, EXIT_REVOKED);
        }
        if Instant::now() >= *deadline {
            return finish(&mut child, EXIT_DEADLINE);
        }
        let mut fds = [
            PollFd::from_borrowed_fd(control, PollFlags::IN | PollFlags::HUP),
            PollFd::from_borrowed_fd(diag_read.as_fd(), PollFlags::IN | PollFlags::HUP),
        ];
        match rustix::event::poll(
            &mut fds,
            Some(&rustix::event::Timespec {
                tv_sec: 0,
                tv_nsec: 25_000_000,
            }),
        ) {
            Err(Errno::INTR) => continue,
            Err(_) => return finish(&mut child, EXIT_REVOKED),
            Ok(_) => {}
        }
        if !fds[0].revents().is_empty() {
            let mut chunk = [0_u8; CONTROL_FRAME_LIMIT];
            match rustix::io::read(control, &mut chunk) {
                Ok(0) | Err(_) => return finish(&mut child, EXIT_REVOKED),
                Ok(count) => {
                    for byte in chunk[..count].iter() {
                        if *byte == b'\n' {
                            match parse_control(&frame) {
                                Some(Control::Renew(lease)) => {
                                    *deadline =
                                        Instant::now() + Duration::from_millis(u64::from(lease));
                                }
                                _ => return finish(&mut child, EXIT_REVOKED),
                            }
                            frame.clear();
                        } else {
                            if frame.len() >= CONTROL_FRAME_LIMIT - 1 {
                                return finish(&mut child, EXIT_REVOKED);
                            }
                            frame.push(*byte);
                        }
                    }
                }
            }
        }
        let mut discard = [0_u8; 4096];
        match rustix::io::read(&diag_read, &mut discard) {
            Err(Errno::AGAIN) | Err(Errno::INTR) => {}
            Err(_) => return finish(&mut child, EXIT_DIAGNOSTICS),
            Ok(count) => {
                diagnostics_total += count;
                if diagnostics_total > DIAGNOSTICS_LIMIT {
                    return finish(&mut child, EXIT_DIAGNOSTICS);
                }
            }
        }
        match waitid(
            WaitId::Pid(sender_pid),
            WaitIdOptions::EXITED | WaitIdOptions::NOHANG | WaitIdOptions::NOWAIT,
        ) {
            Err(Errno::INTR) => continue,
            Err(_) => return finish(&mut child, EXIT_SENDER_FAILED),
            Ok(Some(status)) => {
                let code = if status.exit_status() == Some(0) {
                    0
                } else {
                    1
                };
                let finished = finish(&mut child, code);
                // Writers are reaped; drain the remaining bounded diagnostics.
                loop {
                    match rustix::io::read(&diag_read, &mut discard) {
                        Err(_) | Ok(0) => break,
                        Ok(count) => diagnostics_total += count,
                    }
                }
                if diagnostics_total > DIAGNOSTICS_LIMIT {
                    return EXIT_DIAGNOSTICS;
                }
                return finished;
            }
            Ok(None) => {}
        }
    }
}

fn spawn_sender(request: &Request, diag_write: OwnedFd) -> Result<std::process::Child, ()> {
    let mut builder = Process::new(&request.sender);
    builder
        .args(&request.arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::from(diag_write));
    builder.process_group(0);
    pin_sender::pin(&mut builder, getpid());
    builder.spawn().map_err(|_| ())
}

#[allow(unsafe_code)]
mod pin_sender {
    use rustix::process::{getppid, set_parent_process_death_signal, Pid, Signal};
    use std::os::unix::process::CommandExt;
    use std::process::Command;

    /// @cc [owner:ghuntley,label:recovery] source-export-pins-parent-fencing
    /// The sender must not outlive its lease owner: set the parent-death signal
    /// and verify the recorded parent before exec. The only unsafe-declared API
    /// used is std's `pre_exec`; its body stays in safe typed rustix calls.
    pub(super) fn pin(command: &mut Command, parent: Pid) {
        unsafe {
            command.pre_exec(move || {
                if set_parent_process_death_signal(Some(Signal::KILL)).is_err()
                    || getppid() != Some(parent)
                {
                    return Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied));
                }
                // Runtime-ignored SIGPIPE must not outlive exec into senders.
                libc::signal(libc::SIGPIPE, libc::SIG_DFL);
                Ok(())
            })
        };
    }
}

/// @cc [owner:ghuntley,label:recovery] source-export-reap-before-release
/// finish MUST kill the private sender process group and reap all adopted
/// children in every process group/session before releasing transfer ownership. The leader MUST remain
/// unreaped until this point, preventing PID reuse. An uncertain reap MUST
/// never confirm quiescence.
fn finish(child: &mut std::process::Child, status: u8) -> u8 {
    let pid = match i32::try_from(child.id()).ok().and_then(Pid::from_raw) {
        Some(pid) => pid,
        None => return EXIT_IO,
    };
    let _ = kill_process_group(pid, Signal::KILL);
    let _ = child.kill();
    if child.wait().is_err() {
        return EXIT_IO;
    }
    // Subreaper adoption: every grandchild is ours until ECHILD.
    loop {
        match wait(WaitOptions::empty()) {
            Err(Errno::INTR) => continue,
            Err(Errno::CHILD) => return status,
            Err(_) => return EXIT_IO,
            Ok(_) => continue,
        }
    }
}

#[cfg(test)]
mod tests;

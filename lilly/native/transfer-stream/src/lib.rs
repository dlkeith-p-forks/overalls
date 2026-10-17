#![deny(unsafe_code)]
#![doc = "Trusted, non-setuid pipeline owner. Disk bytes stay in kernel pipes."]

use rustix::event::{PollFd, PollFlags};
use rustix::fs::{flock, open, FlockOperation, Mode as FileMode, OFlags};
use rustix::io::Errno;
use rustix::pipe::{pipe_with, splice, PipeFlags, SpliceFlags};
use rustix::process::{getpid, kill_process, kill_process_group, set_child_subreaper};
use rustix::process::{wait, waitid, Pid, Signal, WaitId, WaitIdOptions, WaitOptions};
use std::ffi::{OsStr, OsString};
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::CommandExt as _;
use std::path::{Path, PathBuf};
use std::process::{Command as Process, Stdio};
use std::time::{Duration, Instant};

pub const EXIT_USAGE: u8 = 64;
pub const EXIT_SETUP: u8 = 70;
pub const EXIT_INSECURE_LOCK: u8 = 73;
pub const EXIT_IO: u8 = 74;

/// Byte total cap for the producer + consumer argument vector.
pub const ARGV_TOTAL_LIMIT: usize = 65536;
/// Maximum consumer argv entries.
pub const CONSUMER_ARGS_LIMIT: usize = 128;
/// Producer argv entries live between 1 and 128 inclusive.
pub const PRODUCER_ARGS_LIMIT: usize = 128;
/// Largest transferred diagnostics window in bytes.
pub const DIAGNOSTICS_LIMIT: usize = 65536;
/// Rate credit quantum, in byte-milliseconds (64 KiB per second of credit).
pub const CREDIT_CAP_MS: i64 = 65_536_000;
/// Per-iteration splice ceiling in bytes.
pub const SPLICE_WINDOW: usize = 65536;
/// Maximum number of bounded caller bytes in the startup nonce.
pub const NONCE_LIMIT: usize = 128;

/// A validated invocation.
#[derive(Debug, Eq, PartialEq)]
pub struct Request {
    pub lock: PathBuf,
    pub timeout_ms: u64,
    pub producer: Vec<OsString>,
    pub consumer: Vec<OsString>,
    pub rate: u64,
    pub progress: bool,
}

/// Environment configuration accepted from the caller's explicit settings.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct StreamConfig {
    pub rate: u64,
    pub progress: bool,
}

/// Strict decimal: nonempty, no leading zeros, digits only, then bounds.
fn number(text: &OsStr, min: i64, max: i64) -> Option<i64> {
    let bytes = text.as_bytes();
    if bytes.is_empty() || (bytes[0] == b'0' && bytes.len() > 1) {
        return None;
    }
    if !bytes.iter().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    let value: i64 = text.parse().ok()?;
    (min..=max).contains(&value).then_some(value)
}

pub fn parse_env(progress: Option<&str>, rate: Option<&str>) -> Option<StreamConfig> {
    let progress = match progress {
        None => false,
        Some("0") => false,
        Some("1") => true,
        Some(_) => return None,
    };
    let rate = match rate {
        None => 0,
        Some(text) => u64::try_from(number(OsStr::new(text), 0, 1_073_741_824)?).ok()?,
    };
    Some(StreamConfig { rate, progress })
}

/// @cc [owner:ghuntley,label:security] transfer-cli-bounded-absolute
/// Only trusted absolute argv: lock, timeout, producer count then absolute
/// producer and consumer argv entries; the byte span never exceeds 65536.
pub fn parse_cli(arguments: &[OsString]) -> Option<Request> {
    let [lock, timeout, producers, rest @ ..] = arguments else {
        return None;
    };
    let timeout_ms: u64 = u64::try_from(number(timeout, 1000, 86_400_000)?).ok()?;
    let producer_count = usize::try_from(number(producers, 1, PRODUCER_ARGS_LIMIT as i64)?).ok()?;
    // rest covers every producer argv entry followed by every consumer entry;
    // the C split is 4+producers with an absolute-head check on both sides.
    if rest.len() < producer_count + 1 || rest.len() - producer_count > CONSUMER_ARGS_LIMIT {
        return None;
    }
    let (producer, consumer) = rest.split_at(producer_count);
    if !lock.as_os_str().as_bytes().starts_with(b"/")
        || producer.is_empty()
        || !producer[0].as_os_str().as_bytes().starts_with(b"/")
        || !consumer[0].as_os_str().as_bytes().starts_with(b"/")
    {
        return None;
    }
    if producer
        .iter()
        .chain(consumer.iter())
        .any(|arg| arg.is_empty() || arg.as_os_str().as_bytes().contains(&0))
    {
        return None;
    }
    let argument_bytes: usize = producer
        .iter()
        .chain(consumer.iter())
        .map(|arg| arg.as_os_str().as_bytes().len() + 1)
        .sum();
    if argument_bytes > ARGV_TOTAL_LIMIT {
        return None;
    }
    Some(Request {
        lock: PathBuf::from(lock),
        timeout_ms,
        producer: producer.to_vec(),
        consumer: consumer.to_vec(),
        rate: 0,
        progress: false,
    })
}

pub fn with_env(request: &mut Request) -> bool {
    match parse_env(
        std::env::var("LILLY_TRANSFER_PROGRESS").ok().as_deref(),
        std::env::var("LILLY_TRANSFER_BYTES_PER_SECOND")
            .ok()
            .as_deref(),
    ) {
        None => false,
        Some(config) => {
            request.rate = config.rate;
            request.progress = config.progress;
            true
        }
    }
}

fn read_nonce(input: BorrowedFd<'_>) -> Option<Vec<u8>> {
    let mut nonce = Vec::with_capacity(16);
    loop {
        let mut byte = [0_u8; 1];
        if nonce.len() == NONCE_LIMIT {
            return None;
        }
        match rustix::io::read(input, &mut byte) {
            Err(Errno::INTR) => continue,
            Err(_) | Ok(0) => return None,
            Ok(_) => {}
        }
        nonce.push(byte[0]);
        if byte[0] == b'\n' {
            return Some(nonce);
        }
    }
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

/// Held transfer lock custody.
pub struct Held {
    #[allow(dead_code)]
    descriptor: OwnedFd,
}

fn acquire_lock(path: &Path) -> Result<Held, u8> {
    let descriptor = open(
        path,
        OFlags::RDWR | OFlags::CREATE | OFlags::NOFOLLOW,
        FileMode::from_raw_mode(0o600),
    )
    .map_err(|_| EXIT_INSECURE_LOCK)?;
    let file: std::fs::File = descriptor.into();
    let metadata = file.metadata().map_err(|_| EXIT_INSECURE_LOCK)?;
    let fd: OwnedFd = file.into();
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
    flock(&fd, FlockOperation::NonBlockingLockExclusive).map_err(|_| EXIT_INSECURE_LOCK)?;
    if rustix::fs::fchmod(&fd, FileMode::from_raw_mode(0o600)).is_err() {
        return Err(EXIT_INSECURE_LOCK);
    }
    Ok(Held { descriptor: fd })
}

/// The running register of one side of the pipeline.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Side {
    Running,
    Succeeded,
    Failed,
}

impl Side {
    /// Outcome mapping of one observed pair, mirroring the C order exactly.
    /// The 7-class requires both known-failed at the same observation quantum;
    /// join ordering belongs to the timing of the two exits, never causality.
    fn classify(self, other: Side) -> Option<u8> {
        match (self, other) {
            (Side::Failed, Side::Failed) => Some(7),
            (Side::Failed, _) => Some(5),
            (_, Side::Failed) => Some(6),
            (Side::Succeeded, Side::Succeeded) => Some(0),
            _ => None,
        }
    }
    /// Peek the leader without reaping; the reaps happen in cleanup so a group
    /// id cannot be re-adopted while the sibling side still runs.
    fn poll(child: &std::process::Child) -> Self {
        let pid = child.id();
        let Some(raw) = i32::try_from(pid).ok().and_then(Pid::from_raw) else {
            return Self::Failed;
        };
        match waitid(
            WaitId::Pid(raw),
            WaitIdOptions::EXITED | WaitIdOptions::NOHANG | WaitIdOptions::NOWAIT,
        ) {
            Err(_) => Self::Failed,
            Ok(None) => Self::Running,
            Ok(Some(status)) => {
                if status.exited() && status.exit_status() == Some(0) {
                    Self::Succeeded
                } else {
                    Self::Failed
                }
            }
        }
    }
}

/// @cc [owner:ghuntley,label:recovery] transfer-reap-before-ownership-release
/// finish MUST kill both private process groups and reap all adopted children
/// across every process group/session before
/// releasing ownership. Leaders remain unreaped until this cleanup, preventing
/// PID reuse while another side still runs. Reap uncertainty never confirms
/// quiescence.
fn finish(
    producer: &mut std::process::Child,
    consumer: Option<&mut std::process::Child>,
    status: u8,
) -> u8 {
    let mut uncertain = false;
    if let Some(pid) = i32::try_from(producer.id()).ok().and_then(Pid::from_raw) {
        let _ = kill_process_group(pid, Signal::KILL);
        let _ = kill_process(pid, Signal::KILL);
    } else {
        uncertain = true;
        let _ = producer.kill();
    }
    let mut consumer = consumer;
    #[allow(clippy::needless_option_as_deref)]
    if let Some(side) = consumer.as_mut() {
        if let Some(pid) = i32::try_from(side.id()).ok().and_then(Pid::from_raw) {
            let _ = kill_process_group(pid, Signal::KILL);
            let _ = kill_process(pid, Signal::KILL);
        } else {
            uncertain = true;
            let _ = side.kill();
        }
    }
    uncertain |= producer.wait().is_err();
    #[allow(clippy::needless_option_as_deref)]
    if let Some(side) = consumer.as_mut() {
        uncertain |= side.wait().is_err();
    }
    // Subreaper: adopted descendants are ours until ECHILD.
    loop {
        match wait(WaitOptions::empty()) {
            Err(Errno::INTR) => continue,
            Err(Errno::CHILD) => return if uncertain { EXIT_IO } else { status },
            Err(_) => return EXIT_IO,
            Ok(_) => continue,
        }
    }
}

pub fn run(request: &Request) -> u8 {
    if set_child_subreaper(Some(getpid())).is_err() {
        return EXIT_SETUP;
    }
    let input = std::io::stdin();
    let output = std::io::stdout();
    let Some(nonce) = read_nonce(input.as_fd()) else {
        return EXIT_IO;
    };
    let _held = match acquire_lock(&request.lock) {
        Err(code) => return code,
        Ok(held) => held,
    };
    let pipes = pipe_with(PipeFlags::CLOEXEC)
        .and_then(|data| pipe_with(PipeFlags::CLOEXEC).map(|sink| (data, sink)))
        .and_then(|pair| pipe_with(PipeFlags::CLOEXEC).map(|diag| (pair.0, pair.1, diag)));
    let Ok((data, sink, diag)) = pipes else {
        return EXIT_SETUP;
    };
    let (data_reader, data_writer) = data;
    let (sink_reader, sink_writer) = sink;
    let (diag_reader, diag_writer) = diag;
    if rustix::fs::fcntl_setfl(&diag_reader, OFlags::NONBLOCK).is_err() {
        return EXIT_SETUP;
    }
    if write_all(output.as_fd(), &nonce).is_err() {
        return EXIT_IO;
    }
    if request.progress && rustix::fs::fcntl_setfl(output.as_fd(), OFlags::NONBLOCK).is_err() {
        return EXIT_SETUP;
    }
    transfer(
        request,
        data_reader,
        data_writer,
        sink_reader,
        sink_writer,
        diag_reader,
        diag_writer,
        input.as_fd(),
        output.as_fd(),
    )
}

fn spawn(
    args: &[OsString],
    stdin: Stdio,
    stdout: Stdio,
    stderr: Stdio,
) -> Result<std::process::Child, ()> {
    let mut builder = Process::new(args[0].clone());
    builder
        .args(&args[1..])
        .stdin(stdin)
        .stdout(stdout)
        .stderr(stderr);
    builder.process_group(0);
    pin::to_caller(&mut builder, getpid());
    builder.spawn().map_err(|_| ())
}

#[allow(unsafe_code)]
mod pin {
    use rustix::process::{getppid, set_parent_process_death_signal, Pid, Signal};
    use std::os::unix::process::CommandExt;
    use std::process::Command;

    /// @cc [owner:ghuntley,label:security] transfer-pins-children-to-owner
    /// Producer and consumer must not outlive the helper: set the parent-death
    /// signal and verify the recorded parent before exec; the closure body is
    /// only safe typed rustix calls with no allocation crossing the fork.
    pub(super) fn to_caller(command: &mut Command, parent: Pid) {
        unsafe {
            command.pre_exec(move || {
                if set_parent_process_death_signal(Some(Signal::KILL)).is_err()
                    || getppid() != Some(parent)
                {
                    return Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied));
                }
                libc::signal(libc::SIGPIPE, libc::SIG_DFL);
                Ok(())
            })
        };
    }
}

/// The plumbing harness: three kernel pipes whose writer ends ride into the
/// two children and whose reader ends the caller owns.
#[allow(clippy::too_many_arguments)]
fn transfer(
    request: &Request,
    data_reader: OwnedFd,
    data_writer: OwnedFd,
    sink_reader: OwnedFd,
    sink_writer: OwnedFd,
    diag_reader: OwnedFd,
    diag_writer: OwnedFd,
    input: BorrowedFd<'_>,
    output: BorrowedFd<'_>,
) -> u8 {
    // The C twin-dup2 puts one diag descriptor into both consumer channels.
    let consumer_stdout = match diag_writer.try_clone() {
        Err(_) => return EXIT_SETUP,
        Ok(clone) => clone,
    };
    let consumer_stderr = match diag_writer.try_clone() {
        Err(_) => return EXIT_SETUP,
        Ok(clone) => clone,
    };
    // Producer: stdin=null, stdout=data pipe, stderr=diag (same channel).
    let mut producer = match spawn(
        &request.producer,
        Stdio::null(),
        Stdio::from(data_writer),
        Stdio::from(diag_writer),
    ) {
        Err(_) => return EXIT_SETUP,
        Ok(child) => child,
    };
    // Consumer: stdin=sink reader; stdout and stderr both ride diag into the
    // bounded discard, exactly like the C twin-dup2.
    let mut consumer = match spawn(
        &request.consumer,
        Stdio::from(sink_reader),
        Stdio::from(consumer_stdout),
        Stdio::from(consumer_stderr),
    ) {
        Err(_) => {
            let _ = finish(&mut producer, None, EXIT_SETUP);
            return EXIT_SETUP;
        }
        Ok(child) => child,
    };
    sweep(
        request,
        &mut producer,
        &mut consumer,
        data_reader,
        sink_writer,
        diag_reader,
        input,
        output,
    )
}

#[allow(clippy::too_many_arguments)]
fn sweep(
    request: &Request,
    producer: &mut std::process::Child,
    consumer: &mut std::process::Child,
    data_reader: OwnedFd,
    sink_writer: OwnedFd,
    diag_reader: OwnedFd,
    input: BorrowedFd<'_>,
    output: BorrowedFd<'_>,
) -> u8 {
    let mut last = Instant::now();
    let deadline = last + Duration::from_millis(request.timeout_ms);
    let mut credit: i64 = CREDIT_CAP_MS;
    let mut eof = false;
    let mut copied_total: u64 = 0;
    let mut reported_at = last;
    let mut diagnostics = 0_usize;
    let mut sink = Some(sink_writer);
    loop {
        if Instant::now() >= deadline {
            return finish(producer, Some(consumer), 2);
        }
        let now = Instant::now();
        let elapsed = now.duration_since(last).as_millis() as i64;
        last = now;
        if request.rate != 0 && elapsed > 0 {
            // Clamp elapsed before multiplication to bound arithmetic after suspension.
            let refill = elapsed.min(1000) * i64::try_from(request.rate).unwrap_or(CREDIT_CAP_MS);
            credit = credit.saturating_add(refill).min(CREDIT_CAP_MS);
        }
        let mut delay = 1;
        if !eof {
            let available = if request.rate != 0 {
                usize::try_from(credit / 1000)
                    .unwrap_or(usize::MAX)
                    .min(SPLICE_WINDOW)
            } else {
                SPLICE_WINDOW
            };
            if available > 0 {
                match splice(
                    &data_reader,
                    None,
                    sink.as_ref().expect("live sink"),
                    None,
                    available,
                    SpliceFlags::NONBLOCK | SpliceFlags::MOVE,
                ) {
                    Ok(0) => {
                        drop(sink.take());
                        eof = true;
                    }
                    Ok(count) => {
                        delay = 0;
                        copied_total = match copied_total.checked_add(count as u64) {
                            None => return finish(producer, Some(consumer), 1),
                            Some(total) => total,
                        };
                        if request.rate != 0 {
                            credit -= i64::try_from(count).unwrap_or(0) * 1000;
                        }
                    }
                    Err(Errno::AGAIN) | Err(Errno::INTR) => {}
                    Err(_) => return finish(producer, Some(consumer), 8),
                }
            }
        }
        if request.progress && now.duration_since(reported_at).as_millis() >= 1000 {
            let mut frame = [b'P'; 9];
            frame[1..].copy_from_slice(&copied_total.to_be_bytes());
            if write_all(output, &frame).is_err() {
                return finish(producer, Some(consumer), 4);
            }
            reported_at = now;
        }
        let mut fds = [
            PollFd::from_borrowed_fd(input, PollFlags::IN | PollFlags::HUP),
            PollFd::from_borrowed_fd(diag_reader.as_fd(), PollFlags::IN | PollFlags::HUP),
        ];
        match rustix::event::poll(
            &mut fds,
            Some(&rustix::event::Timespec {
                tv_sec: 0,
                tv_nsec: delay * 1_000_000,
            }),
        ) {
            Err(Errno::INTR) => continue,
            Err(_) => return finish(producer, Some(consumer), 4),
            Ok(_) => {}
        }
        // No bytes after the handshake are legal here; caller data cancels.
        if !fds[0].revents().is_empty() {
            return finish(producer, Some(consumer), 4);
        }
        loop {
            let mut discard = [0_u8; 4096];
            match rustix::io::read(&diag_reader, &mut discard) {
                Err(Errno::AGAIN) | Err(Errno::INTR) => break,
                Err(_) => return finish(producer, Some(consumer), 3),
                Ok(0) => break,
                Ok(count) => {
                    diagnostics += count;
                    if diagnostics > DIAGNOSTICS_LIMIT {
                        return finish(producer, Some(consumer), 3);
                    }
                }
            }
        }
        let a = Side::poll(producer);
        let b = Side::poll(consumer);
        match a.classify(b) {
            Some(0) => {
                // The completion frame reports the final counter before the
                // sweep closes; a blocked sink revokes instead of hanging.
                if request.progress {
                    let mut frame = [b'P'; 9];
                    frame[1..].copy_from_slice(&copied_total.to_be_bytes());
                    if write_all(output, &frame).is_err() {
                        return finish(producer, Some(consumer), 4);
                    }
                }
                let status = finish(producer, Some(consumer), 0);
                // Reaped writers cannot race this final bounded diagnostic drain.
                loop {
                    let mut discard = [0_u8; 4096];
                    match rustix::io::read(&diag_reader, &mut discard) {
                        Err(_) | Ok(0) => break,
                        Ok(count) => diagnostics += count,
                    }
                }
                return if diagnostics > DIAGNOSTICS_LIMIT {
                    3
                } else {
                    status
                };
            }
            Some(code) => return finish(producer, Some(consumer), code),
            None => {}
        }
    }
}

#[cfg(test)]
mod tests;

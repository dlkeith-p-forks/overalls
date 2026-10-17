#![deny(unsafe_code)]
#![doc = "Drain a child's combined stdout/stderr while retaining a bounded, line-timestamped"]
#![doc = "boot log. No shell, environment lookup, payload diagnostics or text decoding."]

use rustix::fs::{open, Mode as FileMode, OFlags};
use rustix::io::Errno;
use rustix::pipe::{pipe_with, PipeFlags};
use std::ffi::OsString;
use std::os::fd::OwnedFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::ExitStatusExt as _;
use std::path::{Path, PathBuf};
use std::process::{Command as Process, Stdio};
use std::time::{Duration, Instant};

/// Retained boot log bytes, counted into the output file only.
pub const BOOT_LOG_LIMIT: usize = 1024 * 1024;

pub const EXIT_USAGE: u8 = 64;
pub const EXIT_CHILD_SETUP: u8 = 71;
pub const EXIT_CUSTODY: u8 = 74;

/// A validated invocation: an absolute private log path and an absolute command.
#[derive(Debug, Eq, PartialEq)]
pub struct Request {
    pub log: PathBuf,
    pub program: PathBuf,
    pub arguments: Vec<OsString>,
}

pub fn parse_cli(arguments: &[OsString]) -> Option<Request> {
    let [log, program, rest @ ..] = arguments else {
        return None;
    };
    for absolute in [log, program] {
        if !absolute.as_os_str().as_bytes().starts_with(b"/") {
            return None;
        }
    }
    Some(Request {
        log: PathBuf::from(log),
        program: PathBuf::from(program),
        arguments: rest.to_vec(),
    })
}

/// Open the output file and prove it is a private, single-link, owner-only
/// regular inode. Symlink resolutions and stranger inodes are refused.
fn open_log(path: &Path) -> Result<std::fs::File, ()> {
    let fd = open(
        path,
        OFlags::WRONLY | OFlags::CREATE | OFlags::TRUNC | OFlags::NOFOLLOW,
        FileMode::from_raw_mode(0o600),
    )
    .map_err(|_| ())?;
    let file: std::fs::File = fd.into();
    let metadata = file.metadata().map_err(|_| ())?;
    let private = metadata.is_file()
        && metadata.nlink() == 1
        && metadata.uid() == rustix::process::geteuid().as_raw()
        && metadata.mode() & 0o777 == 0o600;
    if private {
        Ok(file)
    } else {
        Err(())
    }
}

/// Console line-start state. The only state is whether the next byte begins a
/// line, so the stamped output is independent of how the pipe chunks bytes.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LineState {
    /// The next byte other than CR/LF begins a new line and receives a prefix.
    LineStart,
    /// The current line already carries its prefix.
    MidLine,
}

/// @cc [owner:ghuntley,label:recovery] boot-log-line-timestamps
/// Every console line that contains a byte other than CR/LF MUST be prefixed
/// with exactly one `[+S.mmm] ` host-monotonic offset from writer start, taken
/// when the line's first byte is read. CR and LF both end a line, so CRLF and
/// carriage-return redraws never split or duplicate a prefix; empty lines get
/// none. Payload bytes are copied unchanged and, for a fixed clock reading, the
/// output is independent of read chunking.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Stamper {
    state: LineState,
}

impl Default for Stamper {
    fn default() -> Self {
        Self::new()
    }
}

impl Stamper {
    pub const fn new() -> Self {
        Self {
            state: LineState::LineStart,
        }
    }

    pub const fn state(&self) -> LineState {
        self.state
    }

    /// Append `chunk` to `out`, inserting the `now` prefix at every line start.
    pub fn feed(&mut self, chunk: &[u8], now: Duration, out: &mut Vec<u8>) {
        for &byte in chunk {
            let terminator = byte == b'\n' || byte == b'\r';
            self.state = match (self.state, terminator) {
                (_, true) => LineState::LineStart,
                (LineState::LineStart, false) => {
                    push_prefix(now, out);
                    LineState::MidLine
                }
                (LineState::MidLine, false) => LineState::MidLine,
            };
            out.push(byte);
        }
    }
}

/// Append `[+S.mmm] `: whole seconds unbounded, milliseconds truncated.
pub fn push_prefix(now: Duration, out: &mut Vec<u8>) {
    use std::io::Write as _;
    // Formatting into a Vec cannot fail.
    let _ = write!(out, "[+{}.{:03}] ", now.as_secs(), now.subsec_millis());
}

/// Bounded retention of the stamped stream. Once BOOT_LOG_LIMIT stamped bytes
/// are retained, later input is discarded without stamping.
#[derive(Debug)]
pub struct Retention {
    stamper: Stamper,
    retained: usize,
    scratch: Vec<u8>,
}

impl Default for Retention {
    fn default() -> Self {
        Self::new()
    }
}

impl Retention {
    pub fn new() -> Self {
        Self {
            stamper: Stamper::new(),
            retained: 0,
            scratch: Vec::new(),
        }
    }

    /// The stamped bytes of `chunk` (read at `now`) that still fit the limit.
    pub fn admit(&mut self, chunk: &[u8], now: Duration) -> &[u8] {
        self.scratch.clear();
        let available = BOOT_LOG_LIMIT - self.retained;
        if available > 0 {
            self.stamper.feed(chunk, now, &mut self.scratch);
            self.scratch.truncate(available);
            self.retained += self.scratch.len();
        }
        &self.scratch
    }

    pub const fn retained(&self) -> usize {
        self.retained
    }
}

/// The observed drain ending.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Drained {
    /// Child's writers reached EOF only after exiting.
    Complete,
    /// Reading the child channel failed.
    ReadFailed,
    /// Persisting the retained prefix failed.
    WriteFailed,
}

/// @cc [owner:ghuntley,label:recovery;security] bounded-byte-safe-boot-log
/// The child MUST be drained continuously; at most BOOT_LOG_LIMIT bytes of the
/// line-stamped stream (boot-log-line-timestamps) are persisted without other
/// interpretation, and output beyond the limit is discarded without blocking
/// or terminating the VM. The child's exit
/// status is preserved; a child dead by signal re-raises that signal so the
/// owning service observes a real signal death.
pub fn run(request: &Request) -> u8 {
    let mut output = match open_log(&request.log) {
        Err(()) => return EXIT_CUSTODY,
        Ok(file) => file,
    };
    let Ok((reader, writer)) = pipe_with(PipeFlags::CLOEXEC) else {
        return EXIT_CHILD_SETUP;
    };
    let stderr_writer = match writer.try_clone() {
        Err(_) => return EXIT_CHILD_SETUP,
        Ok(clone) => clone,
    };
    let outcome = {
        let mut builder = Process::new(&request.program);
        builder
            .args(&request.arguments)
            .stdin(Stdio::null())
            .stdout(Stdio::from(writer))
            .stderr(Stdio::from(stderr_writer));
        let spawned = builder.spawn();
        // Dropping the builder closes the parent's copies of both writer ends,
        // so the reader observes EOF exactly when the exec'd image closes them.
        drop(builder);
        spawned
    };
    let mut child = match outcome {
        Err(_) => return EXIT_CHILD_SETUP,
        Ok(child) => child,
    };
    let started = Instant::now();
    match drain(&reader, &mut output, &|| started.elapsed()) {
        Drained::Complete => {}
        Drained::ReadFailed | Drained::WriteFailed => return EXIT_CUSTODY,
    }
    drop(reader);
    settle(&mut child)
}

fn drain(reader: &OwnedFd, output: &mut std::fs::File, clock: &dyn Fn() -> Duration) -> Drained {
    let mut retention = Retention::new();
    let mut buffer = [0_u8; 65536];
    loop {
        match rustix::io::read(reader, &mut buffer) {
            Err(Errno::INTR) => continue,
            Err(_) => return Drained::ReadFailed,
            Ok(0) => return Drained::Complete,
            Ok(count) => {
                let kept = retention.admit(&buffer[..count], clock());
                if !kept.is_empty() {
                    use std::io::Write as _;
                    if output.write_all(kept).is_err() {
                        return Drained::WriteFailed;
                    }
                }
            }
        }
    }
}

fn settle(child: &mut std::process::Child) -> u8 {
    let status = match child.wait() {
        Err(_) => return EXIT_CHILD_SETUP,
        Ok(status) => status,
    };
    if let Some(code) = status.code() {
        return u8::try_from(code).unwrap_or(EXIT_CHILD_SETUP);
    }
    if let Some(signal) = status.signal() {
        // Die with the child's signal; unkillable dispositions land at 71.
        signal_reraise::re_raise(signal);
    }
    EXIT_CHILD_SETUP
}

#[allow(unsafe_code)]
mod signal_reraise {
    /// @cc [owner:ghuntley,label:recovery] boot-log-signal-reraise-shim
    /// Terminating by the child's signal requires restoring the default
    /// disposition and raising it; libc declares both calls unsafe-signatured
    /// so the confinement is exactly this two-call shim with the raw signal
    /// number as the only input.
    pub(super) fn re_raise(signal: libc::c_int) {
        unsafe {
            libc::signal(signal, libc::SIG_DFL);
            libc::raise(signal);
        }
    }
}

#[cfg(test)]
mod tests;

//! Native Unix command deadlines without an external timeout executable.

use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

pub(super) struct Output {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

struct Group(Option<libc::pid_t>);

impl Group {
    fn kill(&mut self) {
        let Some(pid) = self.0.take() else {
            return;
        };
        // SAFETY: the child was started in a new process group with this PID.
        // No command or parent process belongs to the executor's own group.
        unsafe { libc::killpg(pid, libc::SIGKILL) };
    }
}

impl Drop for Group {
    fn drop(&mut self) {
        self.kill();
    }
}

struct Pipe<R> {
    source: R,
    bytes: Vec<u8>,
    eof: bool,
}

impl<R: Read + AsRawFd> Pipe<R> {
    fn new(source: R) -> io::Result<Self> {
        let fd = source.as_raw_fd();
        // SAFETY: source owns the descriptor; only its status flags change.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            source,
            bytes: Vec::new(),
            eof: false,
        })
    }

    fn drain(&mut self, limit: usize) -> io::Result<()> {
        let mut buffer = [0_u8; 4096];
        // Bound work per turn so an endlessly writing pipe cannot prevent
        // checking the deadline or draining the other output stream.
        for _ in 0..16 {
            match self.source.read(&mut buffer) {
                Ok(0) => {
                    self.eof = true;
                    break;
                }
                Ok(count) => {
                    let retained = count.min(limit.saturating_sub(self.bytes.len()));
                    self.bytes.extend_from_slice(&buffer[..retained]);
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }
}

/// @cc [owner:ghuntley,label:security;recovery] native-command-duration-output
/// Native command execution MUST use a separate process group, concurrently
/// drain both output pipes without blocking past the deadline, and retain at
/// most `limit` bytes per stream. At completion, deadline or failure it MUST
/// kill that group and reap the direct child. Descendants that explicitly
/// escape that group MUST NOT keep the executor blocked on inherited pipes.
pub(super) fn run(command: &mut Command, limit: usize, budget: Duration) -> io::Result<Output> {
    command
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn()?;
    let pid = match libc::pid_t::try_from(child.id()) {
        Ok(pid) => pid,
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(io::Error::other("invalid native child PID"));
        }
    };
    let mut group = Group(Some(pid));
    let result = (|| {
        let mut stdout = Pipe::new(
            child
                .stdout
                .take()
                .ok_or_else(|| io::Error::other("missing native stdout"))?,
        )?;
        let mut stderr = Pipe::new(
            child
                .stderr
                .take()
                .ok_or_else(|| io::Error::other("missing native stderr"))?,
        )?;
        let deadline = Instant::now() + budget;
        let mut status = None;
        loop {
            stdout.drain(limit)?;
            stderr.drain(limit)?;
            if status.is_none() {
                status = child.try_wait()?;
                if status.is_some() {
                    group.kill();
                }
            }
            if status.is_some() && stdout.eof && stderr.eof {
                break;
            }
            if Instant::now() >= deadline {
                group.kill();
                if status.is_none() {
                    let _ = child.kill();
                    status = Some(child.wait()?);
                }
                stdout.drain(limit)?;
                stderr.drain(limit)?;
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        Ok(Output {
            status: status.ok_or_else(|| io::Error::other("missing native command status"))?,
            stdout: stdout.bytes,
            stderr: stderr.bytes,
        })
    })();
    group.kill();
    if result.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drains_both_pipes_and_bounds_retained_output() {
        let output = run(
            Command::new("/bin/sh").args([
                "-c",
                "i=0; while [ $i -lt 5000 ]; do printf 1234; printf 5678 >&2; i=$((i+1)); done",
            ]),
            31,
            Duration::from_secs(5),
        )
        .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout.len(), 31);
        assert_eq!(output.stderr.len(), 31);
    }

    #[test]
    fn kills_a_waiting_command_at_its_deadline() {
        let start = Instant::now();
        let output = run(
            Command::new("/bin/sh").args(["-c", "sleep 30 & wait"]),
            32,
            Duration::from_millis(100),
        )
        .unwrap();
        assert!(!output.status.success());
        assert!(start.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn inherited_background_pipes_do_not_block_after_shell_exit() {
        let start = Instant::now();
        let output = run(
            Command::new("/bin/sh").args(["-c", "sleep 30 & exit 0"]),
            32,
            Duration::from_secs(2),
        )
        .unwrap();
        assert!(output.status.success());
        assert!(start.elapsed() < Duration::from_secs(3));
    }
}

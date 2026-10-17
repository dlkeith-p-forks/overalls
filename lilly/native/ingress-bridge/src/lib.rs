#![deny(unsafe_code)]
#![doc = "Byte bridge lilly-hostd runs between a Lilly socket and a guest connection (ADR-0184)."]

use rustix::event::{PollFd, PollFlags};
use rustix::fs::OFlags;
use rustix::io::Errno;
use rustix::net::Shutdown;
use rustix::pipe::{pipe_with, splice, PipeFlags, SpliceFlags};
use std::ffi::{OsStr, OsString};
use std::ops::RangeInclusive;
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;

pub const EXIT_OK: u8 = 0;
pub const EXIT_USAGE: u8 = 64;
pub const EXIT_SETUP: u8 = 70;
pub const EXIT_IO: u8 = 74;

/// Bytes one direction holds in its kernel pipe at most.
pub const WINDOW: usize = 65_536;
/// Accepted inherited descriptors: never stdio.
pub const FDS: RangeInclusive<i64> = 3..=1023;
/// Accepted uids to drop to: never root, never the overflow uid.
pub const UIDS: RangeInclusive<i64> = 1..=4_294_967_294;

/// A validated invocation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Request {
    /// The socket whose peer is Lilly's own socket.
    pub client: i32,
    /// The guest TCP connection hostd dialled inside the namespace.
    pub guest: i32,
    /// The uid (and equal gid) the bridge drops to; None keeps its own.
    pub uid: Option<u32>,
}

/// Strict decimal: nonempty, no leading zeros, digits only, then bounds.
fn number(text: &OsStr, range: &RangeInclusive<i64>) -> Option<i64> {
    let bytes = text.as_bytes();
    if bytes.is_empty() || (bytes[0] == b'0' && bytes.len() > 1) {
        return None;
    }
    if !bytes.iter().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let value: i64 = std::str::from_utf8(bytes).ok()?.parse().ok()?;
    range.contains(&value).then_some(value)
}

/// @cc [owner:ghuntley,label:security] bridge-cli-bounded
/// The command line MUST be exactly `<client fd> <guest fd> [<uid>]`: two
/// distinct strict decimals in 3..=1023 and an optional strict decimal uid in
/// 1..=4294967294. Anything else is refused before any descriptor is used.
pub fn parse_cli(arguments: &[OsString]) -> Option<Request> {
    let (client, guest, uid) = match arguments {
        [client, guest] => (client, guest, None),
        [client, guest, uid] => (client, guest, Some(number(uid, &UIDS)?)),
        _ => return None,
    };
    let client = number(client, &FDS)?;
    let guest = number(guest, &FDS)?;
    if client == guest {
        return None;
    }
    Some(Request {
        client: i32::try_from(client).ok()?,
        guest: i32::try_from(guest).ok()?,
        uid: match uid {
            Some(uid) => Some(u32::try_from(uid).ok()?),
            None => None,
        },
    })
}

/// One direction's custody: bytes read from its source wait in its pipe
/// until they are written to its sink.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Direction {
    /// Bytes in the pipe, read but not yet written.
    pub pending: usize,
    /// The source reported end of stream.
    pub eof: bool,
    /// The sink was shut down for writing.
    pub shut: bool,
}

impl Direction {
    pub fn wants_read(&self) -> bool {
        !self.eof && self.pending < WINDOW
    }

    pub fn wants_write(&self) -> bool {
        self.pending > 0
    }

    pub fn room(&self) -> usize {
        WINDOW - self.pending
    }

    /// Every byte the source sent was delivered.
    pub fn drained(&self) -> bool {
        self.eof && self.pending == 0
    }

    /// Record a source read of `count` bytes; zero is end of stream.
    pub fn read(&mut self, count: usize) {
        if count == 0 {
            self.eof = true;
        } else {
            self.pending += count;
        }
    }

    pub fn wrote(&mut self, count: usize) {
        self.pending -= count;
    }
}

/// @cc [owner:ghuntley,label:recovery] bridge-ends-with-lilly
/// The bridge MUST finish once Lilly's side reached end of stream and every
/// byte it sent was delivered to the guest: Lilly closes only whole sockets,
/// so a silent guest cannot keep a bridge alive. A guest end of stream only
/// shuts Lilly's side for writing, after the guest's bytes were delivered.
pub fn finished(outbound: &Direction) -> bool {
    outbound.drained()
}

/// Whether the guest's end of stream may now be passed to Lilly's side.
pub fn half_close_due(inbound: &Direction) -> bool {
    inbound.drained() && !inbound.shut
}

/// @cc [owner:ghuntley,label:security;isolation] bridge-custody
/// Before any byte moves, both descriptors MUST be sockets, and a given uid
/// MUST be applied (no supplementary groups, that gid and uid, no_new_privs)
/// with the parent-death signal set afterwards and the recorded parent
/// verified. Bytes move only between the two sockets through this process's
/// kernel pipes, never to stdout, stderr or a diagnostic. Any read or write
/// error closes both connections and exits nonzero.
pub fn run(request: &Request) -> u8 {
    let parent = rustix::process::getppid();
    let (Some(client), Some(guest)) = (native::adopt(request.client), native::adopt(request.guest))
    else {
        return EXIT_SETUP;
    };
    if !socket(&client) || !socket(&guest) {
        return EXIT_SETUP;
    }
    if let Some(uid) = request.uid {
        if native::drop_to(uid).is_err() {
            return EXIT_SETUP;
        }
    }
    if rustix::process::set_parent_process_death_signal(Some(rustix::process::Signal::KILL))
        .is_err()
        || rustix::process::getppid() != parent
    {
        return EXIT_SETUP;
    }
    for descriptor in [&client, &guest] {
        let Ok(flags) = rustix::fs::fcntl_getfl(descriptor) else {
            return EXIT_SETUP;
        };
        if rustix::fs::fcntl_setfl(descriptor, flags | OFlags::NONBLOCK).is_err() {
            return EXIT_SETUP;
        }
    }
    let pipes = (
        pipe_with(PipeFlags::CLOEXEC | PipeFlags::NONBLOCK),
        pipe_with(PipeFlags::CLOEXEC | PipeFlags::NONBLOCK),
    );
    let (Ok(outbound_pipe), Ok(inbound_pipe)) = pipes else {
        return EXIT_SETUP;
    };
    bridge(&client, &guest, &outbound_pipe, &inbound_pipe)
}

fn socket(descriptor: &OwnedFd) -> bool {
    rustix::fs::fstat(descriptor).is_ok_and(|stat| stat.st_mode & libc::S_IFMT == libc::S_IFSOCK)
}

/// Move `room` or `pending` bytes; None is an error that ends the bridge.
fn moved(result: rustix::io::Result<usize>) -> Option<Option<usize>> {
    match result {
        Ok(count) => Some(Some(count)),
        Err(Errno::AGAIN) | Err(Errno::INTR) => Some(None),
        Err(_) => None,
    }
}

fn bridge(
    client: &OwnedFd,
    guest: &OwnedFd,
    (outbound_reader, outbound_writer): &(OwnedFd, OwnedFd),
    (inbound_reader, inbound_writer): &(OwnedFd, OwnedFd),
) -> u8 {
    let flags = SpliceFlags::NONBLOCK | SpliceFlags::MOVE;
    let mut outbound = Direction::default();
    let mut inbound = Direction::default();
    loop {
        if finished(&outbound) {
            let _ = rustix::net::shutdown(guest, Shutdown::Write);
            return EXIT_OK;
        }
        if half_close_due(&inbound) {
            let _ = rustix::net::shutdown(client, Shutdown::Write);
            inbound.shut = true;
        }
        let interest = |reads: bool, writes: bool| {
            let mut flags = PollFlags::empty();
            if reads {
                flags |= PollFlags::IN;
            }
            if writes {
                flags |= PollFlags::OUT;
            }
            flags
        };
        let client_interest = interest(outbound.wants_read(), inbound.wants_write());
        let guest_interest = interest(inbound.wants_read(), outbound.wants_write());
        // A side with nothing to do is left out, so a hung-up peer cannot
        // spin the loop while the other side is still delivering.
        let mut fds = Vec::with_capacity(2);
        if !client_interest.is_empty() {
            fds.push(PollFd::from_borrowed_fd(client.as_fd(), client_interest));
        }
        if !guest_interest.is_empty() {
            fds.push(PollFd::from_borrowed_fd(guest.as_fd(), guest_interest));
        }
        if fds.is_empty() {
            // Both sources ended with nothing pending; finished() decides.
            continue;
        }
        match rustix::event::poll(&mut fds, None) {
            Ok(_) | Err(Errno::INTR) => {}
            Err(_) => return EXIT_IO,
        }
        drop(fds);
        if outbound.wants_read() {
            match moved(splice(
                client,
                None,
                outbound_writer,
                None,
                outbound.room(),
                flags,
            )) {
                None => return EXIT_IO,
                Some(Some(count)) => outbound.read(count),
                Some(None) => {}
            }
        }
        if outbound.wants_write() {
            match moved(splice(
                outbound_reader,
                None,
                guest,
                None,
                outbound.pending,
                flags,
            )) {
                None => return EXIT_IO,
                Some(Some(count)) => outbound.wrote(count),
                Some(None) => {}
            }
        }
        if inbound.wants_read() {
            match moved(splice(
                guest,
                None,
                inbound_writer,
                None,
                inbound.room(),
                flags,
            )) {
                None => return EXIT_IO,
                Some(Some(count)) => inbound.read(count),
                Some(None) => {}
            }
        }
        if inbound.wants_write() {
            match moved(splice(
                inbound_reader,
                None,
                client,
                None,
                inbound.pending,
                flags,
            )) {
                None => return EXIT_IO,
                Some(Some(count)) => inbound.wrote(count),
                Some(None) => {}
            }
        }
    }
}

#[allow(unsafe_code)]
mod native {
    use std::os::fd::{FromRawFd, OwnedFd};

    /// Take ownership of an inherited descriptor after checking it is open.
    pub(super) fn adopt(fd: i32) -> Option<OwnedFd> {
        // SAFETY: F_GETFD only inspects the descriptor table entry.
        if unsafe { libc::fcntl(fd, libc::F_GETFD) } == -1 {
            return None;
        }
        // SAFETY: the descriptor is open, was inherited for this process
        // alone, and nothing else in this process refers to it.
        Some(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    /// Drop every supplementary group, then the gid and uid, then set
    /// no_new_privs. The process is single-threaded here, so the libc
    /// wrappers change the whole process's credentials.
    pub(super) fn drop_to(uid: u32) -> std::io::Result<()> {
        // SAFETY: plain credential system calls with valid arguments.
        let failed = unsafe {
            libc::setgroups(0, std::ptr::null()) != 0
                || libc::setresgid(uid, uid, uid) != 0
                || libc::setresuid(uid, uid, uid) != 0
                || libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0
        };
        if failed {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests;

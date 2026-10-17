//! One authenticated client session over a `SOCK_SEQPACKET` connection.

use crate::exec::{self, Custody, Spec};
use crate::leases::Leases;
use crate::protocol::{
    decode, encode_reply, valid_directory, Refusal, Reply, Request, Status, CHUNK_SIZE, JOB_KEY,
    PROTOCOL_VERSION, REQUEST_LIMIT,
};
use crate::utilities::Table;
use rustix::net::{recv, send, RecvFlags, SendFlags};
use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::os::fd::OwnedFd;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// Requests one session may have in flight at once.
pub const MAX_IN_FLIGHT: usize = 1024;
/// How long a finished durable job's result stays attachable.
pub const JOB_RETENTION: Duration = Duration::from_secs(600);
/// Most finished job results retained.
pub const MAX_FINISHED_JOBS: usize = 256;

/// A durable job's state.
enum Job {
    Running,
    Done {
        status: Status,
        bytes: Vec<u8>,
        at: Instant,
    },
}

/// Shared daemon state.
pub struct Daemon {
    pub leases: Leases,
    pub utilities: Table,
    pub custody: Custody,
    pub peer_uid: u32,
    pub peer_cgroups: Vec<Vec<u8>>,
    /// Roots beneath which Firecracker sockets may be opened for Lilly.
    pub socket_roots: Vec<std::path::PathBuf>,
    next_session: AtomicU64,
    jobs: Mutex<HashMap<[u8; JOB_KEY], Job>>,
    jobs_changed: Condvar,
}

impl Daemon {
    pub fn new(
        leases: Leases,
        utilities: Table,
        custody: Custody,
        peer_uid: u32,
        peer_cgroups: Vec<Vec<u8>>,
    ) -> Daemon {
        Daemon {
            leases,
            utilities,
            custody,
            peer_uid,
            peer_cgroups,
            socket_roots: Vec::new(),
            next_session: AtomicU64::new(1),
            jobs: Mutex::new(HashMap::new()),
            jobs_changed: Condvar::new(),
        }
    }
}

struct Run {
    lease: u64,
    cancelled: Arc<AtomicBool>,
}

#[derive(Default)]
struct Book {
    runs: HashMap<u64, Run>,
    busy: HashSet<u64>,
    releasing: HashSet<u64>,
    /// Leases a durable job is using; the job, not session close, frees them.
    durable: HashSet<u64>,
    in_flight: usize,
}

struct Session {
    id: u64,
    socket: OwnedFd,
    daemon: Arc<Daemon>,
    closed: AtomicBool,
    book: Mutex<Book>,
    idle: Condvar,
    writer: Mutex<()>,
}

/// @cc [owner:ghuntley,label:security] hostd-peer-authenticated
/// A session MUST be refused unless the peer's SO_PEERCRED uid equals the
/// configured uid and, when peer cgroups are configured, the peer's cgroup
/// (from /proc/<pid>/cgroup) is one of them. The first datagram MUST be a
/// Hello with this protocol version; anything else closes the session
/// before any lease or command.
pub fn serve(daemon: Arc<Daemon>, socket: OwnedFd) {
    if !authenticated(&daemon, &socket) {
        return;
    }
    let session = Arc::new(Session {
        id: daemon.next_session.fetch_add(1, Ordering::SeqCst),
        socket,
        daemon,
        closed: AtomicBool::new(false),
        book: Mutex::new(Book::default()),
        idle: Condvar::new(),
        writer: Mutex::new(()),
    });
    let mut buffer = vec![0_u8; REQUEST_LIMIT + 1];
    let Some(first) = receive(&session.socket, &mut buffer) else {
        return;
    };
    match decode(first) {
        Some(envelope) => match envelope.request {
            Request::Hello { version } if version == PROTOCOL_VERSION => {
                session.reply(
                    envelope.id,
                    &Reply::Hello {
                        version: PROTOCOL_VERSION,
                    },
                );
            }
            _ => {
                session.reply(
                    envelope.id,
                    &Reply::Refused {
                        reason: Refusal::Version,
                    },
                );
                return;
            }
        },
        None => return,
    }
    while let Some(datagram) = receive(&session.socket, &mut buffer) {
        let Some(envelope) = decode(datagram) else {
            // A malformed datagram ends the session: a confused client must
            // not keep authority.
            break;
        };
        if !session.admit() {
            session.reply(
                envelope.id,
                &Reply::Refused {
                    reason: Refusal::Malformed,
                },
            );
            continue;
        }
        let worker = Arc::clone(&session);
        std::thread::spawn(move || {
            worker.handle(envelope.id, envelope.request);
            worker.done();
        });
    }
    session.close();
}

fn authenticated(daemon: &Daemon, socket: &OwnedFd) -> bool {
    let Ok(credentials) = rustix::net::sockopt::socket_peercred(socket) else {
        return false;
    };
    if credentials.uid.as_raw() != daemon.peer_uid {
        return false;
    }
    if daemon.peer_cgroups.is_empty() {
        return true;
    }
    let Ok(cgroup) = std::fs::read(format!("/proc/{}/cgroup", credentials.pid.as_raw_nonzero()))
    else {
        return false;
    };
    // cgroup v2: a single "0::<path>" line.
    let path = cgroup
        .split(|byte| *byte == b'\n')
        .find_map(|line| line.strip_prefix(b"0::"));
    path.is_some_and(|path| daemon.peer_cgroups.iter().any(|allowed| allowed == path))
}

fn receive<'a>(socket: &OwnedFd, buffer: &'a mut [u8]) -> Option<&'a [u8]> {
    loop {
        match recv(socket, &mut *buffer, RecvFlags::empty()) {
            Ok((0, _)) => return None,
            Ok((size, _)) if size > REQUEST_LIMIT => return None,
            Ok((size, _)) => return Some(&buffer[..size]),
            Err(rustix::io::Errno::INTR) => continue,
            Err(_) => return None,
        }
    }
}

impl Session {
    fn admit(&self) -> bool {
        let mut book = self.book.lock().expect("session book");
        if book.in_flight >= MAX_IN_FLIGHT {
            return false;
        }
        book.in_flight += 1;
        true
    }

    fn done(&self) {
        let mut book = self.book.lock().expect("session book");
        book.in_flight -= 1;
        self.idle.notify_all();
    }

    fn reply(&self, id: u64, reply: &Reply) {
        let datagram = encode_reply(id, reply);
        let _guard = self.writer.lock().expect("session writer");
        // A failed send means the peer is gone; the reader observes EOF.
        let _ = send(&self.socket, &datagram, SendFlags::NOSIGNAL);
    }

    fn refuse(&self, id: u64, reason: Refusal) {
        self.reply(id, &Reply::Refused { reason });
    }

    fn handle(self: &Arc<Self>, id: u64, request: Request) {
        match request {
            Request::Hello { .. } => self.refuse(id, Refusal::Malformed),
            Request::Acquire {
                mode,
                wait_ms,
                directory,
            } => {
                if !valid_directory(&directory) {
                    return self.refuse(id, Refusal::Malformed);
                }
                let path = Path::new(OsStr::from_bytes(&directory));
                match self.daemon.leases.acquire(
                    self.id,
                    mode,
                    path,
                    Duration::from_millis(u64::from(wait_ms)),
                    &self.closed,
                ) {
                    Ok((lease, _)) => {
                        if self.closed.load(Ordering::SeqCst) {
                            self.daemon.leases.release(self.id, lease);
                        } else {
                            self.reply(id, &Reply::Granted { lease });
                        }
                    }
                    Err(reason) => self.refuse(id, reason),
                }
            }
            Request::Release { lease } => {
                if self.daemon.leases.holder(lease) != Some(self.id) {
                    return self.refuse(id, Refusal::UnknownLease);
                }
                self.release(lease);
                self.reply(id, &Reply::Released);
            }
            Request::Cancel { target } => {
                let book = self.book.lock().expect("session book");
                if let Some(run) = book.runs.get(&target) {
                    run.cancelled.store(true, Ordering::SeqCst);
                }
            }
            Request::Run {
                lease,
                timeout_ms,
                output_limit,
                utility,
                arguments,
            } => self.run(id, lease, timeout_ms, output_limit, utility, arguments),
            Request::RunDurable {
                key,
                lease,
                timeout_ms,
                output_limit,
                utility,
                arguments,
            } => self.run_durable(id, key, lease, timeout_ms, output_limit, utility, arguments),
            Request::Attach { key, wait_ms } => self.attach(id, key, wait_ms),
            Request::OpenUnix { path } => {
                let path = Path::new(OsStr::from_bytes(&path));
                let opened = crate::descriptors::open_unix(path, &self.daemon.socket_roots);
                self.reply_descriptor(id, opened);
            }
            Request::OpenNetnsTcp {
                mark,
                destination,
                port,
                source,
                timeout_ms,
                namespace,
                device,
            } => {
                let text = |bytes: Vec<u8>| String::from_utf8(bytes).unwrap_or_default();
                let opened = crate::descriptors::open_netns_tcp(crate::descriptors::NetnsTcp {
                    namespace: text(namespace),
                    device: text(device),
                    mark,
                    destination: std::net::Ipv4Addr::from(destination),
                    port,
                    source: (source != [0, 0, 0, 0]).then(|| std::net::Ipv4Addr::from(source)),
                    timeout: Duration::from_millis(u64::from(timeout_ms)),
                });
                self.reply_descriptor(id, opened);
            }
        }
    }

    /// Reply with a descriptor (SCM_RIGHTS) or the refusal.
    fn reply_descriptor(&self, id: u64, opened: Result<OwnedFd, Refusal>) {
        match opened {
            Ok(descriptor) => {
                let datagram = encode_reply(id, &Reply::Descriptor);
                let _guard = self.writer.lock().expect("session writer");
                let _ =
                    crate::descriptors::send_with_descriptor(&self.socket, &datagram, &descriptor);
            }
            Err(reason) => self.refuse(id, reason),
        }
    }

    /// @cc [owner:ghuntley,label:security;concurrency] hostd-lease-commands-serialized
    /// A command under a lease MUST be refused unless this session holds the
    /// lease, no other command is in flight on it and it is not being
    /// released; a mutating utility MUST be refused without a lease. A lease
    /// therefore runs at most one command at a time, as the per-lock helper
    /// did.
    fn run(
        &self,
        id: u64,
        lease: u64,
        timeout_ms: u32,
        output_limit: u32,
        utility: crate::utilities::Utility,
        arguments: Vec<std::ffi::CString>,
    ) {
        if lease == 0 && utility.mutating() {
            return self.refuse(id, Refusal::LeaseRequired);
        }
        let descriptor = if lease == 0 {
            None
        } else {
            match self.daemon.leases.descriptor(self.id, lease) {
                Some(descriptor) => Some(descriptor),
                None => return self.refuse(id, Refusal::UnknownLease),
            }
        };
        let cancelled = Arc::new(AtomicBool::new(false));
        {
            let mut book = self.book.lock().expect("session book");
            if lease != 0 {
                if book.busy.contains(&lease) || book.releasing.contains(&lease) {
                    return self.refuse(id, Refusal::LeaseBusy);
                }
                book.busy.insert(lease);
            }
            if self.closed.load(Ordering::SeqCst) {
                cancelled.store(true, Ordering::SeqCst);
            }
            book.runs.insert(
                id,
                Run {
                    lease,
                    cancelled: Arc::clone(&cancelled),
                },
            );
        }
        let (status, bytes) = match self.daemon.utilities.get(utility) {
            None => (Status::Setup, Vec::new()),
            Some(executable) => exec::run(
                &Spec {
                    executable,
                    arguments: &arguments,
                    timeout: Duration::from_millis(u64::from(timeout_ms)),
                    output_limit: output_limit as usize,
                    lease: descriptor.as_deref(),
                },
                &self.daemon.custody,
                &cancelled,
            ),
        };
        drop(descriptor);
        {
            let mut book = self.book.lock().expect("session book");
            book.runs.remove(&id);
            book.busy.remove(&lease);
            self.idle.notify_all();
        }
        self.reply_result(id, status, &bytes);
    }

    /// Send a command result, chunked into datagrams of at most CHUNK_SIZE.
    fn reply_result(&self, id: u64, status: Status, bytes: &[u8]) {
        let mut chunks = bytes.chunks(CHUNK_SIZE).peekable();
        if chunks.peek().is_none() {
            return self.reply(
                id,
                &Reply::Result {
                    status,
                    bytes: Vec::new(),
                },
            );
        }
        while let Some(chunk) = chunks.next() {
            if chunks.peek().is_some() {
                self.reply(
                    id,
                    &Reply::Chunk {
                        bytes: chunk.to_vec(),
                    },
                );
            } else {
                self.reply(
                    id,
                    &Reply::Result {
                        status,
                        bytes: chunk.to_vec(),
                    },
                );
            }
        }
    }

    /// @cc [owner:ghuntley,label:recovery;concurrency] durable-job-outlives-session
    /// A durable job MUST require a held lease that has no command in flight,
    /// and MUST refuse a key whose job is still running. It runs on its own
    /// thread: closing the session neither cancels it nor releases its lease.
    /// When it finishes its result is stored under its key for ten minutes;
    /// its lease is released then if its session has closed, and otherwise
    /// stays with the live session. Releasing the lease explicitly still
    /// cancels it first.
    #[allow(clippy::too_many_arguments)]
    fn run_durable(
        self: &Arc<Self>,
        id: u64,
        key: [u8; JOB_KEY],
        lease: u64,
        timeout_ms: u32,
        output_limit: u32,
        utility: crate::utilities::Utility,
        arguments: Vec<std::ffi::CString>,
    ) {
        let Some(descriptor) = (lease != 0)
            .then(|| self.daemon.leases.descriptor(self.id, lease))
            .flatten()
        else {
            return self.refuse(id, Refusal::UnknownLease);
        };
        {
            let mut jobs = self.daemon.jobs.lock().expect("job table");
            if matches!(jobs.get(&key), Some(Job::Running)) {
                drop(jobs);
                return self.refuse(id, Refusal::JobRunning);
            }
            let now = Instant::now();
            jobs.retain(|_, job| match job {
                Job::Running => true,
                Job::Done { at, .. } => now.duration_since(*at) < JOB_RETENTION,
            });
            if jobs.len() >= MAX_FINISHED_JOBS {
                drop(jobs);
                return self.refuse(id, Refusal::Malformed);
            }
            let mut book = self.book.lock().expect("session book");
            if book.busy.contains(&lease) || book.releasing.contains(&lease) {
                return self.refuse(id, Refusal::LeaseBusy);
            }
            book.busy.insert(lease);
            book.durable.insert(lease);
            jobs.insert(key, Job::Running);
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        self.book.lock().expect("session book").runs.insert(
            id,
            Run {
                lease,
                cancelled: Arc::clone(&cancelled),
            },
        );
        let session = Arc::clone(self);
        std::thread::spawn(move || {
            let (status, bytes) = match session.daemon.utilities.get(utility) {
                None => (Status::Setup, Vec::new()),
                Some(executable) => exec::run(
                    &Spec {
                        executable,
                        arguments: &arguments,
                        timeout: Duration::from_millis(u64::from(timeout_ms)),
                        output_limit: output_limit as usize,
                        lease: Some(&descriptor),
                    },
                    &session.daemon.custody,
                    &cancelled,
                ),
            };
            drop(descriptor);
            session.daemon.jobs.lock().expect("job table").insert(
                key,
                Job::Done {
                    status,
                    bytes: bytes.clone(),
                    at: Instant::now(),
                },
            );
            session.daemon.jobs_changed.notify_all();
            let closed = {
                let mut book = session.book.lock().expect("session book");
                book.runs.remove(&id);
                book.busy.remove(&lease);
                book.durable.remove(&lease);
                session.idle.notify_all();
                session.closed.load(Ordering::SeqCst)
            };
            if closed {
                session.daemon.leases.release(session.id, lease);
            } else {
                session.reply_result(id, status, &bytes);
            }
        });
    }

    /// @cc [owner:ghuntley,label:recovery] durable-job-attach
    /// attach MUST reply with a finished job's stored result, wait at most
    /// wait_ms for a running one (refusing JobRunning when the wait ends or
    /// the session closes), and refuse UnknownJob for any other key.
    fn attach(&self, id: u64, key: [u8; JOB_KEY], wait_ms: u32) {
        let deadline = Instant::now() + Duration::from_millis(u64::from(wait_ms));
        let mut jobs = self.daemon.jobs.lock().expect("job table");
        loop {
            match jobs.get(&key) {
                None => {
                    drop(jobs);
                    return self.refuse(id, Refusal::UnknownJob);
                }
                Some(Job::Done { status, bytes, .. }) => {
                    let (status, bytes) = (*status, bytes.clone());
                    drop(jobs);
                    return self.reply_result(id, status, &bytes);
                }
                Some(Job::Running) => {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() || self.closed.load(Ordering::SeqCst) {
                        drop(jobs);
                        return self.refuse(id, Refusal::JobRunning);
                    }
                    jobs = self
                        .daemon
                        .jobs_changed
                        .wait_timeout(jobs, remaining.min(Duration::from_millis(50)))
                        .expect("job table")
                        .0;
                }
            }
        }
    }

    /// @cc [owner:ghuntley,label:recovery] lease-release-after-commands-reaped
    /// Releasing a lease MUST cancel its in-flight command and wait until that
    /// command was killed and reaped before the descriptor is dropped, so no
    /// successor is granted while a utility of the old holder may still run.
    fn release(&self, lease: u64) {
        let mut book = self.book.lock().expect("session book");
        book.releasing.insert(lease);
        for run in book.runs.values().filter(|run| run.lease == lease) {
            run.cancelled.store(true, Ordering::SeqCst);
        }
        while book.busy.contains(&lease) {
            book = self.idle.wait(book).expect("session book");
        }
        book.releasing.remove(&lease);
        drop(book);
        self.daemon.leases.release(self.id, lease);
    }

    /// @cc [owner:ghuntley,label:recovery] session-close-custody
    /// When a session ends (EOF, a malformed datagram or a socket error) every
    /// queued acquisition MUST stop, every command except a durable job MUST
    /// be killed and reaped, and only then MUST its leases be released; a
    /// durable job's lease is released by the job when it finishes. A Lilly crash therefore
    /// fences exactly like the death of the old per-lock helpers.
    fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        self.daemon.leases.wake();
        self.daemon.jobs_changed.notify_all();
        let mut book = self.book.lock().expect("session book");
        let cancel = |book: &Book| {
            for run in book
                .runs
                .values()
                .filter(|run| !book.durable.contains(&run.lease))
            {
                run.cancelled.store(true, Ordering::SeqCst);
            }
        };
        cancel(&book);
        while book.in_flight > 0 {
            book = self.idle.wait(book).expect("session book");
            cancel(&book);
        }
        let durable = book.durable.clone();
        drop(book);
        for lease in self.daemon.leases.held_by(self.id) {
            if !durable.contains(&lease) {
                self.daemon.leases.release(self.id, lease);
            }
        }
    }
}

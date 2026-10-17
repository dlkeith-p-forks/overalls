use crate::exec::{start_reaper, Custody};
use crate::leases::Leases;
use crate::protocol::*;
use crate::session::{serve, Daemon};
use crate::utilities::{Table, Utility};
use hegel::{generators as gs, TestCase};
use rustix::net::{
    connect, recv, send, socket_with, AddressFamily, RecvFlags, SendFlags, SocketAddrUnix,
    SocketFlags, SocketType,
};
use std::ffi::{CString, OsString};
use std::os::fd::OwnedFd;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------- protocol

/// Independent model of an acceptable Run body.
fn spec_run(
    timeout: u32,
    limit: u32,
    utility: u8,
    arguments: &[Vec<u8>],
    terminated: bool,
) -> bool {
    (1000..=14_400_000).contains(&timeout)
        && (limit == 65_536 || limit == 4_194_304)
        && usize::from(utility) < Utility::ALL.len()
        && arguments.len() <= 127
        && terminated
        && arguments.iter().all(|argument| !argument.contains(&0))
}

/// @cc [owner:ghuntley,label:verification] hostd-decoder-oracle
/// Generated Run datagrams MUST be classified by an independent model, and
/// every accepted datagram MUST re-encode to exactly the received bytes. The
/// decoder is never compared to itself.
#[hegel::test]
fn run_decoding_matches_independent_model(tc: TestCase) {
    let timeout = tc.draw(hegel::one_of!(
        gs::integers::<u32>().min_value(990).max_value(1010),
        gs::integers::<u32>()
            .min_value(14_399_990)
            .max_value(14_400_010),
        gs::integers::<u32>(),
    ));
    let limit = tc.draw(hegel::one_of!(
        gs::just(65_536_u32),
        gs::just(4_194_304_u32),
        gs::integers::<u32>(),
    ));
    let utility = tc.draw(gs::integers::<u8>().min_value(0).max_value(40));
    let count = tc.draw(gs::integers::<usize>().min_value(0).max_value(130));
    let terminated = tc.draw(gs::booleans());
    let arguments: Vec<Vec<u8>> = (0..count)
        .map(|_| tc.draw(gs::binary().max_size(6)))
        .map(|argument| argument.into_iter().filter(|byte| *byte != 0).collect())
        .collect();
    let mut body = vec![OP_RUN_FOR_TEST];
    body.extend(7_u64.to_be_bytes());
    body.extend(3_u64.to_be_bytes());
    body.extend(timeout.to_be_bytes());
    body.extend(limit.to_be_bytes());
    body.push(utility);
    for (index, argument) in arguments.iter().enumerate() {
        body.extend(argument);
        if terminated || index + 1 < arguments.len() {
            body.push(0);
        }
    }
    // An unterminated empty last argument is the same bytes as no argument.
    let mut model_arguments = arguments.clone();
    let mut model_terminated = terminated || arguments.is_empty();
    if !terminated && model_arguments.last().is_some_and(|last| last.is_empty()) {
        model_arguments.pop();
        model_terminated = true;
    }
    let accepted = spec_run(timeout, limit, utility, &model_arguments, model_terminated);
    let decoded = decode(&body);
    assert_eq!(decoded.is_some(), accepted, "body {body:?}");
    if let Some(envelope) = decoded {
        assert_eq!(encode_request(&envelope), body);
    }
}

const OP_RUN_FOR_TEST: u8 = 4;

/// @cc [owner:ghuntley,label:verification] hostd-directory-model
/// Acquire datagrams MUST be accepted exactly when the directory is
/// absolute, NUL-free, at most 4096 bytes and has no empty, `.` or `..`
/// component, and the wait is at most 120000 ms.
#[hegel::test]
fn acquire_decoding_matches_model(tc: TestCase) {
    let parts: Vec<Vec<u8>> = (0..tc.draw(gs::integers::<usize>().min_value(0).max_value(5)))
        .map(|_| {
            tc.draw(hegel::one_of!(
                gs::just(b"a".to_vec()),
                gs::just(b".".to_vec()),
                gs::just(b"..".to_vec()),
                gs::just(Vec::new()),
                gs::binary().max_size(4),
            ))
        })
        .collect();
    let absolute = tc.draw(gs::booleans());
    let mut directory = Vec::new();
    for part in &parts {
        if absolute || !directory.is_empty() {
            directory.push(b'/');
        }
        directory.extend(part);
    }
    let wait = tc.draw(hegel::one_of!(
        gs::integers::<u32>().min_value(0).max_value(10),
        gs::integers::<u32>().min_value(119_990).max_value(120_010),
    ));
    let mode = tc.draw(gs::integers::<u8>().min_value(0).max_value(2));
    let mut body = vec![2_u8];
    body.extend(9_u64.to_be_bytes());
    body.push(mode);
    body.extend(wait.to_be_bytes());
    body.extend(&directory);
    let model = mode <= 1
        && wait <= 120_000
        && directory.first() == Some(&b'/')
        && !directory.contains(&0)
        && directory[1..]
            .split(|byte| *byte == b'/')
            .all(|part| !part.is_empty() && part != b"." && part != b"..");
    assert_eq!(decode(&body).is_some(), model, "directory {directory:?}");
}

/// Replies round-trip through the reference decoder.
#[hegel::test]
fn replies_round_trip(tc: TestCase) {
    let id = tc.draw(gs::integers::<u64>());
    let bytes = tc.draw(gs::binary().max_size(64));
    let reply = match tc.draw(gs::integers::<u8>().min_value(0).max_value(5)) {
        0 => Reply::Hello { version: 1 },
        1 => Reply::Granted {
            lease: tc.draw(gs::integers::<u64>()),
        },
        2 => Reply::Refused {
            reason: Refusal::LeaseBusy,
        },
        3 => Reply::Released,
        4 => Reply::Chunk { bytes },
        _ => Reply::Result {
            status: Status::Cancelled,
            bytes,
        },
    };
    assert_eq!(decode_reply(&encode_reply(id, &reply)), Some((id, reply)));
}

/// Mutating utilities and the closed table stay in step with Lilly's list.
#[test]
fn utility_table_is_dense_and_mutations_marked() {
    for (index, utility) in Utility::ALL.iter().enumerate() {
        assert_eq!(usize::from(utility.index()), index);
        assert_eq!(Utility::from_index(index as u8), Some(*utility));
    }
    assert_eq!(Utility::from_index(Utility::ALL.len() as u8), None);
    for utility in [
        Utility::ImageCopy,
        Utility::Mv,
        Utility::Rm,
        Utility::ZfsMutation,
        Utility::Mount,
        Utility::Umount,
        Utility::SystemdRun,
        Utility::Chown,
    ] {
        assert!(utility.mutating());
    }
    for utility in [
        Utility::Zfs,
        Utility::Stat,
        Utility::Systemctl,
        Utility::ImageIdentity,
    ] {
        assert!(!utility.mutating());
    }
}

// ------------------------------------------------------------------ leases

fn leases(root: &Path) -> Leases {
    Leases::new(&[root.to_path_buf()]).expect("root opens")
}

/// @cc [owner:ghuntley,label:verification;concurrency] lease-fifo-property
/// For generated sequences of exclusive and shared waiters queued behind a
/// held exclusive lease, grants MUST follow arrival order (shared waiters
/// may share a grant with the shared waiters directly before them) and no
/// exclusive lease may ever overlap another lease on the same inode.
#[hegel::test(test_cases = 30)]
fn lease_grants_follow_arrival_order(tc: TestCase) {
    let modes: Vec<Mode> = (0..tc.draw(gs::integers::<usize>().min_value(1).max_value(6)))
        .map(|_| {
            if tc.draw(gs::booleans()) {
                Mode::Shared
            } else {
                Mode::Exclusive
            }
        })
        .collect();
    let directory = tempfile::tempdir().expect("tempdir");
    let table = Arc::new(leases(directory.path()));
    let never = Arc::new(AtomicBool::new(false));
    let (first, _) = table
        .acquire(0, Mode::Exclusive, directory.path(), Duration::ZERO, &never)
        .expect("first lease");
    let log = Arc::new(Mutex::new(Vec::<(usize, &'static str, Mode)>::new()));
    let mut threads = Vec::new();
    for (index, mode) in modes.iter().copied().enumerate() {
        let table = Arc::clone(&table);
        let log = Arc::clone(&log);
        let never = Arc::clone(&never);
        let path = directory.path().to_path_buf();
        threads.push(std::thread::spawn(move || {
            let (lease, _) = table
                .acquire(
                    index as u64 + 1,
                    mode,
                    &path,
                    Duration::from_secs(20),
                    &never,
                )
                .expect("granted");
            log.lock().unwrap().push((index, "granted", mode));
            std::thread::sleep(Duration::from_millis(15));
            log.lock().unwrap().push((index, "released", mode));
            table.release(index as u64 + 1, lease);
        }));
        // Arrival order is the order threads reach the queue.
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(table.release(0, first));
    for thread in threads {
        thread.join().expect("waiter");
    }
    let log = log.lock().unwrap();
    // Grant order follows arrival order. Consecutive shared waiters form one
    // group that may be granted together, in any order within the group.
    let mut groups = Vec::new();
    let mut group = 0;
    for (index, mode) in modes.iter().enumerate() {
        if index > 0 && !(*mode == Mode::Shared && modes[index - 1] == Mode::Shared) {
            group += 1;
        }
        groups.push(group);
    }
    let grants: Vec<usize> = log
        .iter()
        .filter(|(_, event, _)| *event == "granted")
        .map(|(index, _, _)| groups[*index])
        .collect();
    let mut sorted = grants.clone();
    sorted.sort_unstable();
    assert_eq!(grants, sorted, "log {log:?}");
    // Mutual exclusion: replay the log.
    let mut holders: Vec<Mode> = Vec::new();
    for (_, event, mode) in log.iter() {
        if *event == "granted" {
            assert!(
                !holders.contains(&Mode::Exclusive)
                    && (*mode == Mode::Shared || holders.is_empty()),
                "overlap in {log:?}"
            );
            holders.push(*mode);
        } else {
            let position = holders.iter().position(|held| held == mode).unwrap();
            holders.remove(position);
        }
    }
}

#[test]
fn zero_wait_is_one_attempt_and_contention_is_distinct() {
    let directory = tempfile::tempdir().expect("tempdir");
    let table = leases(directory.path());
    let never = AtomicBool::new(false);
    let (lease, _) = table
        .acquire(1, Mode::Exclusive, directory.path(), Duration::ZERO, &never)
        .unwrap();
    let started = Instant::now();
    assert_eq!(
        table
            .acquire(2, Mode::Exclusive, directory.path(), Duration::ZERO, &never)
            .unwrap_err(),
        Refusal::Contended
    );
    assert!(started.elapsed() < Duration::from_millis(100));
    // Another process's flock is contention too.
    assert!(table.release(1, lease));
    let outside = std::fs::File::open(directory.path().join("owner.lock")).unwrap();
    rustix::fs::flock(
        &outside,
        rustix::fs::FlockOperation::NonBlockingLockExclusive,
    )
    .unwrap();
    assert_eq!(
        table
            .acquire(
                2,
                Mode::Exclusive,
                directory.path(),
                Duration::from_millis(60),
                &never
            )
            .unwrap_err(),
        Refusal::Contended
    );
    drop(outside);
    assert!(table
        .acquire(
            2,
            Mode::Exclusive,
            directory.path(),
            Duration::from_millis(500),
            &never
        )
        .is_ok());
}

#[test]
fn unsafe_inodes_and_paths_outside_roots_are_unavailable() {
    let directory = tempfile::tempdir().expect("tempdir");
    let table = leases(directory.path());
    let never = AtomicBool::new(false);
    let outside = tempfile::tempdir().expect("tempdir");
    assert_eq!(
        table
            .acquire(1, Mode::Exclusive, outside.path(), Duration::ZERO, &never)
            .unwrap_err(),
        Refusal::Unavailable
    );
    // A symlinked component is refused.
    std::os::unix::fs::symlink(outside.path(), directory.path().join("link")).unwrap();
    assert_eq!(
        table
            .acquire(
                1,
                Mode::Exclusive,
                &directory.path().join("link"),
                Duration::ZERO,
                &never
            )
            .unwrap_err(),
        Refusal::Unavailable
    );
    // A group-writable or hard-linked inode is refused.
    let lock = directory.path().join("w");
    std::fs::create_dir(&lock).unwrap();
    std::fs::write(lock.join("owner.lock"), b"").unwrap();
    std::fs::set_permissions(
        lock.join("owner.lock"),
        std::fs::Permissions::from_mode(0o620),
    )
    .unwrap();
    assert_eq!(
        table
            .acquire(1, Mode::Exclusive, &lock, Duration::ZERO, &never)
            .unwrap_err(),
        Refusal::Unavailable
    );
    let linked = directory.path().join("l");
    std::fs::create_dir(&linked).unwrap();
    std::fs::write(linked.join("owner.lock"), b"").unwrap();
    std::fs::hard_link(linked.join("owner.lock"), directory.path().join("extra")).unwrap();
    assert_eq!(
        table
            .acquire(1, Mode::Exclusive, &linked, Duration::ZERO, &never)
            .unwrap_err(),
        Refusal::Unavailable
    );
}

// ----------------------------------------------------------------- session

struct Fixture {
    _directory: tempfile::TempDir,
    socket: PathBuf,
    root: PathBuf,
}

fn script(directory: &Path, name: &str, body: &str) {
    let path = directory.join(name);
    std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// A daemon on a private socket whose utility table resolves to test scripts:
/// `stat` echoes its arguments, `truncate` (mutating) sleeps for $1 seconds
/// and `realpath` prints $1 bytes.
fn daemon() -> Fixture {
    start_reaper().expect("subreaper");
    let directory = tempfile::tempdir().expect("tempdir");
    let bin = directory.path().join("bin");
    let root = directory.path().join("root");
    std::fs::create_dir(&bin).unwrap();
    std::fs::create_dir(&root).unwrap();
    script(&bin, "stat", "echo \"$@\"");
    script(&bin, "truncate", "sleep \"$1\"");
    script(&bin, "realpath", "head -c \"$1\" /dev/zero");
    let mut path = OsString::from(&bin);
    path.push(":");
    path.push(std::env::var_os("PATH").unwrap_or_default());
    let daemon = Arc::new(Daemon::new(
        Leases::new(std::slice::from_ref(&root)).unwrap(),
        Table::resolve(&path),
        Custody::ProcessGroup,
        rustix::process::geteuid().as_raw(),
        Vec::new(),
    ));
    let socket = directory.path().join("hostd.sock");
    let listener = socket_with(
        AddressFamily::UNIX,
        SocketType::SEQPACKET,
        SocketFlags::CLOEXEC,
        None,
    )
    .unwrap();
    rustix::net::bind(&listener, &SocketAddrUnix::new(&socket).unwrap()).unwrap();
    rustix::net::listen(&listener, 16).unwrap();
    std::thread::spawn(move || loop {
        let Ok(connection) = rustix::net::accept_with(&listener, SocketFlags::CLOEXEC) else {
            return;
        };
        let daemon = Arc::clone(&daemon);
        std::thread::spawn(move || serve(daemon, connection));
    });
    Fixture {
        _directory: directory,
        socket,
        root,
    }
}

struct Client {
    socket: OwnedFd,
}

impl Client {
    fn connect(fixture: &Fixture) -> Client {
        let socket = socket_with(
            AddressFamily::UNIX,
            SocketType::SEQPACKET,
            SocketFlags::CLOEXEC,
            None,
        )
        .unwrap();
        connect(&socket, &SocketAddrUnix::new(&fixture.socket).unwrap()).unwrap();
        let client = Client { socket };
        client.send(1, Request::Hello { version: 1 });
        assert_eq!(client.receive(), (1, Reply::Hello { version: 1 }));
        client
    }

    fn send(&self, id: u64, request: Request) {
        send(
            &self.socket,
            &encode_request(&Envelope { id, request }),
            SendFlags::NOSIGNAL,
        )
        .unwrap();
    }

    fn receive(&self) -> (u64, Reply) {
        let mut buffer = vec![0_u8; 70_000];
        let (size, _) = recv(&self.socket, &mut buffer, RecvFlags::empty()).unwrap();
        decode_reply(&buffer[..size]).expect("reply decodes")
    }

    fn acquire(&self, id: u64, directory: &Path, wait_ms: u32) -> Reply {
        self.send(
            id,
            Request::Acquire {
                mode: Mode::Exclusive,
                wait_ms,
                directory: directory.as_os_str().as_encoded_bytes().to_vec(),
            },
        );
        self.receive().1
    }

    fn run(&self, id: u64, lease: u64, utility: Utility, arguments: &[&str], timeout_ms: u32) {
        self.send(
            id,
            Request::Run {
                lease,
                timeout_ms,
                output_limit: 65_536,
                utility,
                arguments: arguments
                    .iter()
                    .map(|a| CString::new(*a).unwrap())
                    .collect(),
            },
        );
    }

    /// Collect a command's chunks and final result.
    fn result(&self) -> (Status, Vec<u8>) {
        let mut bytes = Vec::new();
        loop {
            match self.receive().1 {
                Reply::Chunk { bytes: chunk } => bytes.extend(chunk),
                Reply::Result {
                    status,
                    bytes: rest,
                } => {
                    bytes.extend(rest);
                    return (status, bytes);
                }
                other => panic!("unexpected {other:?}"),
            }
        }
    }
}

#[test]
fn hello_is_required_and_version_checked() {
    let fixture = daemon();
    let socket = socket_with(
        AddressFamily::UNIX,
        SocketType::SEQPACKET,
        SocketFlags::CLOEXEC,
        None,
    )
    .unwrap();
    connect(&socket, &SocketAddrUnix::new(&fixture.socket).unwrap()).unwrap();
    let client = Client { socket };
    client.send(5, Request::Hello { version: 2 });
    assert_eq!(
        client.receive(),
        (
            5,
            Reply::Refused {
                reason: Refusal::Version
            }
        )
    );
}

#[test]
fn commands_capture_output_and_mutations_need_a_lease() {
    let fixture = daemon();
    let client = Client::connect(&fixture);
    client.run(2, 0, Utility::Stat, &["one", "two"], 5000);
    assert_eq!(client.result(), (Status::Succeeded, b"one two\n".to_vec()));
    client.run(3, 0, Utility::Truncate, &["0"], 5000);
    assert_eq!(
        client.receive(),
        (
            3,
            Reply::Refused {
                reason: Refusal::LeaseRequired
            }
        )
    );
    // Output larger than one datagram arrives in chunks and reassembles.
    client.run(4, 0, Utility::Realpath, &["100000"], 5000);
    assert_eq!(client.result(), (Status::OutputLimit, Vec::new()));
    client.run(5, 0, Utility::Realpath, &["60000"], 5000);
    let (status, bytes) = client.result();
    assert_eq!((status, bytes.len()), (Status::Succeeded, 60_000));
}

#[test]
fn timeouts_kill_and_leases_serialize_commands() {
    let fixture = daemon();
    let client = Client::connect(&fixture);
    let Reply::Granted { lease } = client.acquire(2, &fixture.root, 0) else {
        panic!("lease")
    };
    let started = Instant::now();
    client.run(3, lease, Utility::Truncate, &["30"], 1000);
    // A second command on the same lease is refused while one runs.
    std::thread::sleep(Duration::from_millis(100));
    client.run(4, lease, Utility::Truncate, &["0"], 1000);
    assert_eq!(
        client.receive(),
        (
            4,
            Reply::Refused {
                reason: Refusal::LeaseBusy
            }
        )
    );
    assert_eq!(client.result(), (Status::TimedOut, Vec::new()));
    assert!(started.elapsed() < Duration::from_secs(5));
}

/// @cc [owner:ghuntley,label:verification;recovery] session-death-fences
/// Closing a session with a command in flight MUST kill that command and
/// release its lease, after which another session is granted the lease; a
/// release likewise cancels its lease's command first.
#[test]
fn session_death_kills_commands_and_releases_leases() {
    let fixture = daemon();
    let first = Client::connect(&fixture);
    let Reply::Granted { lease } = first.acquire(2, &fixture.root, 0) else {
        panic!("lease")
    };
    first.run(3, lease, Utility::Truncate, &["30"], 60_000);
    std::thread::sleep(Duration::from_millis(100));
    let second = Client::connect(&fixture);
    assert_eq!(
        second.acquire(2, &fixture.root, 0),
        Reply::Refused {
            reason: Refusal::Contended
        }
    );
    let started = Instant::now();
    drop(first);
    assert!(matches!(
        second.acquire(3, &fixture.root, 10_000),
        Reply::Granted { .. }
    ));
    assert!(started.elapsed() < Duration::from_secs(5));
    // Release cancels the in-flight command before replying.
    let third_root = fixture.root.join("third");
    std::fs::create_dir(&third_root).unwrap();
    let Reply::Granted { lease } = second.acquire(4, &third_root, 0) else {
        panic!("lease")
    };
    second.run(5, lease, Utility::Truncate, &["30"], 60_000);
    std::thread::sleep(Duration::from_millis(100));
    second.send(6, Request::Release { lease });
    let mut replies = vec![second.receive(), second.receive()];
    replies.sort_by_key(|(id, _)| *id);
    assert_eq!(
        replies,
        vec![
            (
                5,
                Reply::Result {
                    status: Status::Cancelled,
                    bytes: Vec::new()
                }
            ),
            (6, Reply::Released)
        ]
    );
}

#[test]
fn options_parse_strictly() {
    let parse = |items: &[&str]| {
        crate::parse_options(&items.iter().map(OsString::from).collect::<Vec<_>>())
    };
    assert!(parse(&["--socket", "/run/s", "--root", "/var/lib/lilly"]).is_some());
    assert!(parse(&["--socket", "/run/s"]).is_none());
    assert!(parse(&["--socket", "run/s", "--root", "/x"]).is_none());
    assert!(
        parse(&["--socket", "/run/s", "--root", "/x", "--cgroup", "self"])
            .is_some_and(|options| options.cgroup == Some(None))
    );
    assert!(parse(&["--socket", "/a", "--socket", "/b", "--root", "/x"]).is_none());
    assert!(parse(&["--socket", "/a", "--root", "/x", "--peer-uid", "nobody"]).is_none());
    assert!(parse(&["--socket", "/a", "--root", "/x", "--bogus", "1"]).is_none());
}

/// @cc [owner:ghuntley,label:verification;recovery] durable-job-survives-session
/// A durable job MUST keep running and keep its lease after its session
/// closes; another session MUST be able to attach to its result, and is
/// granted the lease only once the job finished.
#[test]
fn durable_jobs_outlive_their_session() {
    let fixture = daemon();
    let key = [7_u8; JOB_KEY];
    let first = Client::connect(&fixture);
    let Reply::Granted { lease } = first.acquire(2, &fixture.root, 0) else {
        panic!("lease")
    };
    first.send(
        3,
        Request::RunDurable {
            key,
            lease,
            timeout_ms: 10_000,
            output_limit: 65_536,
            utility: Utility::Truncate,
            arguments: vec![CString::new("1").unwrap()],
        },
    );
    std::thread::sleep(Duration::from_millis(100));
    drop(first);
    let second = Client::connect(&fixture);
    // The job still holds the lease.
    assert_eq!(
        second.acquire(2, &fixture.root, 0),
        Reply::Refused {
            reason: Refusal::Contended
        }
    );
    second.send(
        3,
        Request::Attach {
            key,
            wait_ms: 10_000,
        },
    );
    assert_eq!(second.result(), (Status::Succeeded, Vec::new()));
    assert!(matches!(
        second.acquire(4, &fixture.root, 2_000),
        Reply::Granted { .. }
    ));
    second.send(
        5,
        Request::Attach {
            key: [9_u8; JOB_KEY],
            wait_ms: 0,
        },
    );
    assert_eq!(
        second.receive(),
        (
            5,
            Reply::Refused {
                reason: Refusal::UnknownJob
            }
        )
    );
}

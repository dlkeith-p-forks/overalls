#![forbid(unsafe_code)]

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command as Process, Stdio};
use std::time::{Duration, Instant};

const HELPER: &str = env!("CARGO_BIN_EXE_lilly-transfer-stream");

struct EscapedChildren(Vec<rustix::process::Pid>);

impl Drop for EscapedChildren {
    fn drop(&mut self) {
        for pid in &self.0 {
            let _ = rustix::process::kill_process(*pid, rustix::process::Signal::KILL);
        }
    }
}

fn published_pid(path: &Path) -> rustix::process::Pid {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(pid) = std::fs::read_to_string(path)
            .ok()
            .and_then(|value| value.trim().parse::<i32>().ok())
            .and_then(rustix::process::Pid::from_raw)
        {
            return pid;
        }
        assert!(
            Instant::now() < deadline,
            "complete process witness required"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
#[ignore = "stream fixture"]
fn fixture_producer_escaped_children() {
    spawn_escaped_children("producer");
}

#[test]
#[ignore = "stream fixture"]
fn fixture_consumer_escaped_children() {
    spawn_escaped_children("consumer");
    fixture_consumer();
}

fn spawn_escaped_children(role: &str) {
    let root = PathBuf::from(std::env::var_os("HL_ESCAPE_ROOT").expect("fixture root"));
    let count = std::env::var("HL_ESCAPE_COUNT")
        .expect("fixture count")
        .parse::<usize>()
        .expect("bounded count");
    assert!((1..=3).contains(&count));
    std::fs::write(
        root.join(format!("{role}.pid")),
        std::process::id().to_string(),
    )
    .expect("direct side witness");
    for index in 0..count {
        let child = Process::new(harness())
            .args([
                "--exact",
                "fixture_escaped_stream_child",
                "--ignored",
                "--nocapture",
            ])
            .env("HL_ESCAPE_PID", root.join(format!("escaped-{index}.pid")))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("escaped fixture child");
        drop(child);
        published_pid(&root.join(format!("escaped-{index}.pid")));
    }
    if std::env::var_os("HL_ESCAPE_HOLD").is_some() {
        while !root.join("release-side").exists() {
            std::thread::sleep(Duration::from_millis(5));
        }
        std::process::exit(19);
    }
}

#[test]
#[ignore = "stream fixture"]
fn fixture_escaped_stream_child() {
    let session = rustix::process::setsid().expect("independent session");
    assert_eq!(
        session.as_raw_nonzero().get(),
        i32::try_from(std::process::id()).expect("PID")
    );
    std::fs::write(
        std::env::var_os("HL_ESCAPE_PID").expect("private PID witness"),
        std::process::id().to_string(),
    )
    .expect("complete escaped witness");
    std::thread::sleep(Duration::from_secs(60));
}

/// @cc [owner:ghuntley,label:verification;recovery] transfer-all-adopted-sessions
/// Completed producer/consumer processes MUST NOT release helper custody while
/// independently witnessed adopted children in other sessions remain alive.
/// Explicit child death MUST permit confirmed reaping and exact helper success.
/// This local kernel property does not establish ZFS or authenticated transfer acceptance.
#[hegel::test(test_cases = 2)]
fn escaped_stream_children_are_reaped_before_owner_exit(tc: hegel::TestCase) {
    let drawn = tc.draw(hegel::generators::sampled_from(&[1_usize, 2, 3]));
    for (role, count) in [StreamSide::Producer, StreamSide::Consumer]
        .into_iter()
        .flat_map(|role| [1, 3, drawn].into_iter().map(move |count| (role, count)))
    {
        let directory = tempfile::tempdir().expect("native fixture directory");
        let root = directory.path().to_str().expect("fixture path").to_owned();
        let count_text = count.to_string();
        let producer_pid = directory.path().join("producer.pid");
        let consumer_pid = directory.path().join("consumer.pid");
        let producer_path = producer_pid.to_str().expect("producer path");
        let consumer_path = consumer_pid.to_str().expect("consumer path");
        let (producer, consumer) = match role {
            StreamSide::Producer => ("fixture_producer_escaped_children", "fixture_consumer"),
            StreamSide::Consumer => ("fixture_producer", "fixture_consumer_escaped_children"),
        };
        let (mut helper, mut control, mut output) = spawn(
            &directory,
            "10000",
            &fixture_args(producer),
            &fixture_args(consumer),
            &[
                ("HL_ESCAPE_ROOT", &root),
                ("HL_ESCAPE_COUNT", &count_text),
                ("HL_PROD_PIDFILE", producer_path),
                ("HL_CONS_PIDFILE", consumer_path),
                ("HL_PROD_BYTES", "0"),
                ("LILLY_TRANSFER_PROGRESS", "0"),
                ("LILLY_TRANSFER_BYTES_PER_SECOND", "0"),
            ],
        );
        handshake(&mut control, &mut output);
        let mut guards = EscapedChildren(Vec::new());
        let producer = published_pid(&producer_pid);
        let consumer = published_pid(&consumer_pid);
        for index in 0..count {
            let pid = published_pid(&directory.path().join(format!("escaped-{index}.pid")));
            guards.0.push(pid);
            let stat = std::fs::read_to_string(format!("/proc/{pid}/stat"))
                .expect("independent escaped process");
            let fields: Vec<&str> = stat
                .rsplit_once(") ")
                .expect("process name")
                .1
                .split_whitespace()
                .collect();
            assert_ne!(pid, producer);
            assert_ne!(pid, consumer);
            assert_eq!(
                fields[2].parse::<i32>().expect("process group"),
                pid.as_raw_nonzero().get()
            );
            assert_eq!(
                fields[3].parse::<i32>().expect("session"),
                pid.as_raw_nonzero().get()
            );
        }
        let completion_deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if [producer, consumer].into_iter().all(process_retired) {
                break;
            }
            assert!(
                Instant::now() < completion_deadline,
                "both direct sides must complete independently: {role:?}"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        let outcome = helper.0.try_wait().expect("helper status");
        let escaped_alive = guards.0.iter().all(|pid| {
            std::fs::read_to_string(format!("/proc/{pid}/stat"))
                .ok()
                .and_then(|stat| {
                    stat.rsplit_once(") ")
                        .map(|(_, fields)| !fields.starts_with("Z ") && !fields.starts_with("X "))
                })
                .unwrap_or(false)
        });
        assert!(escaped_alive, "independent escaped child liveness required");
        assert!(outcome.is_none(), "adopted children must retain stream custody after completion: role={role:?}, count={count}, outcome={outcome:?}, escaped_alive={escaped_alive}");
        for pid in &guards.0 {
            rustix::process::kill_process(*pid, rustix::process::Signal::KILL)
                .expect("explicit fixture child death");
        }
        assert_eq!(helper.wait_bounded(Duration::from_secs(5)).code(), Some(0));
        for pid in &guards.0 {
            assert!(
                !Path::new(&format!("/proc/{pid}")).exists(),
                "adopted child must be reaped before helper exit"
            );
        }
        guards.0.clear();
    }
}

#[derive(Clone, Copy, Debug)]
enum EscapeFailure {
    CallerEof,
    Deadline,
    SideFailure,
}

/// @cc [owner:ghuntley,label:verification;recovery] transfer-failed-adopted-custody
/// Caller EOF, deadline expiry and either failed side MUST retain the helper's
/// owner lock while independently witnessed escaped descendants remain alive.
/// Confirmed reaping after explicit descendant death MUST preserve the trigger's
/// exact failure status and permit successor lock admission.
// Real fixed deadline histories take over30seconds; only the input-speed
// health check is inapplicable. All custody assertions and deadlines remain.
#[hegel::test(test_cases = 2, suppress_health_check = [hegel::HealthCheck::TooSlow])]
fn escaped_stream_failure_retains_lock_until_actual_reaping(tc: hegel::TestCase) {
    let role = tc.draw(hegel::generators::sampled_from(&[
        StreamSide::Producer,
        StreamSide::Consumer,
    ]));
    let trigger = tc.draw(hegel::generators::sampled_from(&[
        EscapeFailure::CallerEof,
        EscapeFailure::Deadline,
        EscapeFailure::SideFailure,
    ]));
    let count = tc.draw(hegel::generators::sampled_from(&[1_usize, 2, 3]));
    let fixed = [StreamSide::Producer, StreamSide::Consumer]
        .into_iter()
        .flat_map(|role| {
            [
                EscapeFailure::CallerEof,
                EscapeFailure::Deadline,
                EscapeFailure::SideFailure,
            ]
            .into_iter()
            .flat_map(move |trigger| [1, 3].into_iter().map(move |count| (role, trigger, count)))
        });
    for (role, trigger, count) in fixed.chain(std::iter::once((role, trigger, count))) {
        failed_escape_case(role, trigger, count);
    }
}

fn failed_escape_case(role: StreamSide, trigger: EscapeFailure, count: usize) {
    use rustix::fs::{flock, FlockOperation};
    let directory = tempfile::tempdir().expect("failure fixture directory");
    let root = directory.path().to_str().expect("root path");
    let producer_path = directory.path().join("producer.pid");
    let consumer_path = directory.path().join("consumer.pid");
    let count_text = count.to_string();
    let (producer, consumer) = match role {
        StreamSide::Producer => ("fixture_producer_escaped_children", "fixture_consumer_idle"),
        StreamSide::Consumer => ("fixture_producer_idle", "fixture_consumer_escaped_children"),
    };
    let timeout = if matches!(trigger, EscapeFailure::Deadline) {
        "5000"
    } else {
        "20000"
    };
    let (mut helper, control, mut output) = spawn(
        &directory,
        timeout,
        &fixture_args(producer),
        &fixture_args(consumer),
        &[
            ("HL_ESCAPE_ROOT", root),
            ("HL_ESCAPE_COUNT", &count_text),
            ("HL_ESCAPE_HOLD", "1"),
            (
                "HL_PROD_PIDFILE",
                producer_path.to_str().expect("producer path"),
            ),
            (
                "HL_CONS_PIDFILE",
                consumer_path.to_str().expect("consumer path"),
            ),
            ("LILLY_TRANSFER_PROGRESS", "0"),
            ("LILLY_TRANSFER_BYTES_PER_SECOND", "0"),
        ],
    );
    let mut control = Some(control);
    handshake(control.as_mut().expect("live caller"), &mut output);
    let producer_pid = published_pid(&producer_path);
    let consumer_pid = published_pid(&consumer_path);
    let mut guards = EscapedChildren(Vec::new());
    for index in 0..count {
        let pid = published_pid(&directory.path().join(format!("escaped-{index}.pid")));
        guards.0.push(pid);
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).expect("escaped process");
        let fields: Vec<&str> = stat
            .rsplit_once(") ")
            .expect("process name")
            .1
            .split_whitespace()
            .collect();
        assert_ne!(pid, producer_pid);
        assert_ne!(pid, consumer_pid);
        assert_eq!(
            fields[2].parse::<i32>().expect("group"),
            pid.as_raw_nonzero().get()
        );
        assert_eq!(
            fields[3].parse::<i32>().expect("session"),
            pid.as_raw_nonzero().get()
        );
        assert!(
            !process_retired(pid),
            "escaped child must be independently live"
        );
    }
    match trigger {
        EscapeFailure::CallerEof => drop(control.take()),
        EscapeFailure::Deadline => {}
        EscapeFailure::SideFailure => std::fs::write(directory.path().join("release-side"), "fail")
            .expect("release failed side"),
    }
    let deadline = Instant::now() + Duration::from_secs(10);
    while ![producer_pid, consumer_pid]
        .into_iter()
        .all(process_retired)
    {
        assert!(
            Instant::now() < deadline,
            "both direct sides must retire: {role:?}/{trigger:?}"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(
        guards.0.iter().all(|pid| !process_retired(*pid)),
        "escaped descendants must remain live"
    );
    assert!(
        helper.0.try_wait().expect("helper status").is_none(),
        "uncertain descendant custody: {role:?}/{trigger:?}/{count}"
    );
    let successor = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(directory.path().join("owner.lock"))
        .expect("successor lock file");
    assert_eq!(
        flock(&successor, FlockOperation::NonBlockingLockExclusive),
        Err(rustix::io::Errno::WOULDBLOCK)
    );
    for pid in &guards.0 {
        rustix::process::kill_process(*pid, rustix::process::Signal::KILL)
            .expect("explicit child death");
    }
    let expected = match trigger {
        EscapeFailure::CallerEof => 4,
        EscapeFailure::Deadline => 2,
        EscapeFailure::SideFailure => match role {
            StreamSide::Producer => 5,
            StreamSide::Consumer => 6,
        },
    };
    assert_eq!(
        helper.wait_bounded(Duration::from_secs(5)).code(),
        Some(expected),
        "exact trigger status: {role:?}/{trigger:?}"
    );
    for pid in &guards.0 {
        assert!(
            !Path::new(&format!("/proc/{pid}")).exists(),
            "every adopted PID must be reaped"
        );
    }
    guards.0.clear();
    flock(&successor, FlockOperation::NonBlockingLockExclusive)
        .expect("successor lock after confirmed death");
}

#[derive(Clone, Copy, Debug)]
enum StreamSide {
    Producer,
    Consumer,
}

fn process_retired(pid: rustix::process::Pid) -> bool {
    match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
        Ok(stat) => stat
            .rsplit_once(") ")
            .is_some_and(|(_, fields)| fields.starts_with("Z ")),
        _ => false,
    }
}

struct Running(Child);

impl Running {
    fn wait_bounded(&mut self, timeout: Duration) -> std::process::ExitStatus {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(status) = self.0.try_wait().expect("polled helper") {
                return status;
            }
            if Instant::now() > deadline {
                let _ = self.0.kill();
                panic!("helper did not exit in time");
            }
            std::thread::sleep(Duration::from_millis(15));
        }
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn harness() -> String {
    std::env::current_exe()
        .expect("harness path")
        .to_string_lossy()
        .into_owned()
}

fn fixture_args(fixture: &str) -> Vec<String> {
    vec![
        harness(),
        "--exact".to_string(),
        fixture.to_string(),
        "--ignored".to_string(),
        "--nocapture".to_string(),
    ]
}

fn spawn(
    directory: &tempfile::TempDir,
    timeout_ms: &str,
    producer: &[String],
    consumer: &[String],
    envs: &[(&str, &str)],
) -> (Running, std::process::ChildStdin, std::process::ChildStdout) {
    use std::os::unix::fs::PermissionsExt as _;
    let lock = directory.path().join("owner.lock");
    drop(std::fs::File::create(&lock).expect("fixture lock"));
    std::fs::set_permissions(&lock, std::fs::Permissions::from_mode(0o600)).expect("private");
    let mut command = Process::new(HELPER);
    command
        .arg(&lock)
        .arg(timeout_ms)
        .arg(producer.len().to_string())
        .args(producer)
        .args(consumer)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .envs(envs.iter().map(|(key, value)| (*key, *value)));
    let mut child = Running(command.spawn().expect("spawned transfer helper"));
    let stdin = child.0.stdin.take().expect("stdin");
    let stdout = child.0.stdout.take().expect("stdout");
    (child, stdin, stdout)
}

fn handshake(stdin: &mut std::process::ChildStdin, stdout: &mut std::process::ChildStdout) {
    stdin.write_all(b"stream-nonce\n").expect("nonce");
    stdin.flush().expect("flushed");
    let mut echo = vec![0_u8; b"stream-nonce\n".len()];
    stdout.read_exact(&mut echo).expect("echo");
    assert_eq!(echo, b"stream-nonce\n");
}

fn countfile(dir: &tempfile::TempDir) -> PathBuf {
    dir.path().join("consumer.count")
}

// -- Fixtures. --

#[test]
#[ignore = "stream fixture"]
fn fixture_producer() {
    use std::io::Write as _;
    if let Ok(value) = std::env::var("HL_PROD_DELAY_MS") {
        std::thread::sleep(Duration::from_millis(value.parse().expect("numeric delay")));
    }
    let bytes: usize = std::env::var("HL_PROD_BYTES")
        .expect("bytes")
        .parse()
        .expect("numeric bytes");
    if let Ok(path) = std::env::var("HL_PROD_PIDFILE") {
        std::fs::write(path, format!("{}", std::process::id())).expect("pid");
    }
    let mut out = std::io::stdout().lock();
    let chunk = [b'x'; 4096];
    let mut remaining = bytes;
    while remaining > 0 {
        let count = remaining.min(4096);
        out.write_all(&chunk[..count]).expect("chunk");
        out.flush().expect("flush");
        remaining -= count;
    }
    let code: i32 = std::env::var("HL_PROD_EXIT")
        .unwrap_or_else(|_| "0".to_string())
        .parse()
        .expect("numeric exit");
    std::process::exit(code);
}

#[test]
#[ignore = "stream fixture"]
fn fixture_consumer() {
    if let Some(path) = std::env::var_os("HL_CONS_PIDFILE") {
        std::fs::write(path, std::process::id().to_string()).expect("consumer PID witness");
    }
    // Count only the producer's 'x' payload bytes so libtest banners on stdout
    // cannot skew the verification.
    if let Ok(value) = std::env::var("HL_CONS_DELAY_MS") {
        std::thread::sleep(Duration::from_millis(value.parse().expect("numeric delay")));
    }
    let mut sink = std::io::stdin().lock();
    let mut total = 0_u64;
    let mut buffer = [0_u8; 65536];
    loop {
        let read = sink.read(&mut buffer).expect("consumer read");
        if read == 0 {
            break;
        }
        total += buffer[..read].iter().filter(|byte| **byte == b'x').count() as u64;
    }
    if let Ok(path) = std::env::var("HL_CONS_COUNTFILE") {
        std::fs::write(path, format!("{total}")).expect("count file");
    }
    let code: i32 = std::env::var("HL_CONS_EXIT")
        .unwrap_or_else(|_| "0".to_string())
        .parse()
        .expect("numeric exit");
    std::process::exit(code);
}

#[test]
#[ignore = "stream fixture"]
fn fixture_producer_idle() {
    if let Ok(path) = std::env::var("HL_PROD_PIDFILE") {
        std::fs::write(path, format!("{}", std::process::id())).expect("pid");
    }
    std::thread::sleep(Duration::from_secs(60));
}

#[test]
#[ignore = "stream fixture"]
fn fixture_side_diag() {
    use std::io::Write as _;
    let mut err = std::io::stderr().lock();
    for _ in 0..20 {
        err.write_all(&[b'!'; 4096]).expect("diag chunk");
    }
    err.flush().expect("flush");
}

// -- Cases. --

#[test]
fn transfer_flows_bytes_to_the_consumer_and_exits_zero() {
    let dir = tempfile::tempdir().expect("fixture");
    let count = countfile(&dir);
    let producer = fixture_args("fixture_producer");
    let consumer = fixture_args("fixture_consumer");
    let count_string = count.to_string_lossy().into_owned();
    let (mut helper, mut stdin, mut stdout) = spawn(
        &dir,
        "30000",
        &producer,
        &consumer,
        &[
            ("HL_PROD_BYTES", "131072"),
            ("HL_CONS_COUNTFILE", count_string.as_str()),
        ],
    );
    handshake(&mut stdin, &mut stdout);
    assert_eq!(helper.wait_bounded(Duration::from_secs(30)).code(), Some(0));
    assert_eq!(
        std::fs::read_to_string(&count).expect("count").trim(),
        "131072"
    );
    let mut rest = Vec::new();
    stdout.read_to_end(&mut rest).expect("post-handshake");
    assert!(rest.is_empty(), "helper stdout carried only the handshake");
}

#[test]
fn revoke_after_handshake_kills_and_reports_four() {
    let dir = tempfile::tempdir().expect("fixture");
    let pidfile = dir.path().join("producer.pid");
    let pid_string = pidfile.to_string_lossy().into_owned();
    let (mut helper, mut stdin, mut stdout) = spawn(
        &dir,
        "30000",
        &fixture_args("fixture_producer_idle"),
        &fixture_args("fixture_consumer"),
        &[("HL_PROD_PIDFILE", pid_string.as_str())],
    );
    handshake(&mut stdin, &mut stdout);
    // Wait for the producer to be up before cancelling so the kill is
    // observable rather than an empty convergence.
    let start = Instant::now();
    while !pidfile.exists() {
        assert!(
            start.elapsed() < Duration::from_secs(10),
            "producer pidfile"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    stdin.write_all(b"anything-here-cancels\n").expect("cancel");
    stdin.flush().expect("flush");
    assert_eq!(helper.wait_bounded(Duration::from_secs(15)).code(), Some(4));
    let pid: i32 = std::fs::read_to_string(&pidfile)
        .expect("pidfile")
        .trim()
        .parse()
        .expect("numeric");
    let proc = format!("/proc/{pid}");
    let deadline = Instant::now() + Duration::from_secs(10);
    while Path::new(&proc).exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(!Path::new(&proc).exists(), "producer survived revocation");
}

#[test]
fn deadline_expiry_reports_two() {
    let dir = tempfile::tempdir().expect("fixture");
    let (mut helper, mut stdin, mut stdout) = spawn(
        &dir,
        "1000",
        &fixture_args("fixture_producer_idle"),
        &fixture_args("fixture_consumer"),
        &[],
    );
    handshake(&mut stdin, &mut stdout);
    assert_eq!(helper.wait_bounded(Duration::from_secs(15)).code(), Some(2));
}

#[test]
fn excessive_diagnostics_report_three() {
    let dir = tempfile::tempdir().expect("fixture");
    let (mut helper, mut stdin, mut stdout) = spawn(
        &dir,
        "30000",
        &fixture_args("fixture_side_diag"),
        &fixture_args("fixture_side_diag"),
        &[],
    );
    handshake(&mut stdin, &mut stdout);
    assert_eq!(helper.wait_bounded(Duration::from_secs(15)).code(), Some(3));
}
#[test]
fn side_failures_distinguish_roles() {
    // Producer fails only: five.
    let dir = tempfile::tempdir().expect("fixture");
    let (mut helper, mut stdin, mut stdout) = spawn(
        &dir,
        "30000",
        &fixture_args("fixture_producer"),
        &fixture_args("fixture_consumer"),
        &[("HL_PROD_EXIT", "9"), ("HL_PROD_BYTES", "1024")],
    );
    handshake(&mut stdin, &mut stdout);
    assert_eq!(helper.wait_bounded(Duration::from_secs(15)).code(), Some(5));

    // Consumer fails only: six.
    let dir = tempfile::tempdir().expect("fixture");
    let (mut helper, mut stdin, mut stdout) = spawn(
        &dir,
        "30000",
        &fixture_args("fixture_producer"),
        &fixture_args("fixture_consumer"),
        &[("HL_PROD_BYTES", "1024"), ("HL_CONS_EXIT", "33")],
    );
    handshake(&mut stdin, &mut stdout);
    assert_eq!(helper.wait_bounded(Duration::from_secs(15)).code(), Some(6));
}

#[test]
fn usage_variants_exit_sixty_four() {
    let dir = tempfile::tempdir().expect("fixture");
    for lock in [Path::new("relative.lock"), countfile(&dir).as_path()] {
        let mut command = Process::new(HELPER);
        command
            .arg(lock)
            .arg("not-a-timeout")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = Running(command.spawn().expect("spawned helper"));
        assert_eq!(child.wait_bounded(Duration::from_secs(10)).code(), Some(64));
    }
}

#[test]
fn contended_lock_reports_seventy_three_after_consuming_nonce() {
    use rustix::fs::{flock, FlockOperation};
    use std::os::unix::fs::PermissionsExt as _;
    let dir = tempfile::tempdir().expect("fixture");
    let lock = dir.path().join("owner.lock");
    drop(std::fs::File::create(&lock).expect("lock"));
    std::fs::set_permissions(&lock, std::fs::Permissions::from_mode(0o600)).expect("private");
    let anchor = std::fs::File::options()
        .read(true)
        .write(true)
        .open(&lock)
        .expect("anchor");
    flock(&anchor, FlockOperation::NonBlockingLockExclusive).expect("anchor lock");
    let mut command = Process::new(HELPER);
    let producer_args = fixture_args("fixture_producer_idle");
    let consumer_args = fixture_args("fixture_consumer");
    command
        .arg(&lock)
        .arg("30000")
        .arg(producer_args.len().to_string())
        .args(&producer_args)
        .args(&consumer_args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut helper = Running(command.spawn().expect("spawned"));
    let mut stdin = helper.0.stdin.take().expect("stdin");
    let mut stdout = helper.0.stdout.take().expect("stdout");
    stdin.write_all(b"stream-nonce\n").expect("nonce");
    stdin.flush().expect("flush");
    assert_eq!(
        helper.wait_bounded(Duration::from_secs(15)).code(),
        Some(73)
    );
    let mut rest = Vec::new();
    stdout
        .read_to_end(&mut rest)
        .expect("any echo would be a bug");
    assert!(rest.is_empty());
}

#[test]
#[ignore = "stream fixture"]
fn fixture_consumer_idle() {
    if let Some(path) = std::env::var_os("HL_CONS_PIDFILE") {
        std::fs::write(path, std::process::id().to_string()).expect("consumer PID witness");
    }
    std::thread::sleep(Duration::from_secs(60));
}

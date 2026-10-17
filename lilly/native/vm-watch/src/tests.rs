use super::*;
use hegel::generators as gs;
use hegel::TestCase;
use std::ffi::OsString;

/// @cc [owner:ghuntley,label:verification] hegel-vm-watch-selectors
/// Generated PID texts and cgroup paths MUST be accepted exactly when the
/// independent canonical models accept them; nothing else selects a process.
#[hegel::test]
fn pid_selector_matches_model(tc: TestCase) {
    let candidates = [
        "0", "1", "01", "42", "4194304", "4194305", "99999999", "", "-1", " 7", "7 ", "x",
    ];
    let text = if tc.draw(gs::booleans()) {
        tc.draw(gs::sampled_from(&candidates)).to_string()
    } else {
        tc.draw(gs::integers::<u32>()).to_string()
    };
    let model = !text.is_empty()
        && !text.starts_with('0')
        && text.len() <= 7
        && text.bytes().all(|b| b.is_ascii_digit())
        && text
            .parse::<u32>()
            .is_ok_and(|v| (1..=PID_MAX).contains(&v));
    assert_eq!(pid_value(&text).is_some(), model, "{text:?}");
}

#[hegel::test]
fn cgroup_selector_matches_model(tc: TestCase) {
    let segments = [
        "lilly.slice",
        "overalls-vm-1.service",
        "a",
        ".",
        "..",
        "",
        "x y",
    ];
    let count = tc.draw(gs::integers::<usize>().min_value(0).max_value(4));
    let parts: Vec<&str> = (0..count)
        .map(|_| tc.draw(gs::sampled_from(&segments)))
        .collect();
    let trailing = tc.draw(gs::booleans());
    let mut text = format!("/sys/fs/cgroup/{}", parts.join("/"));
    if trailing {
        text.push('/');
    }
    let model = count > 0
        && !trailing
        && parts
            .iter()
            .all(|p| !p.is_empty() && *p != "." && *p != "..");
    assert_eq!(cgroup_path(&text).is_some(), model, "{text:?}");
    assert!(cgroup_path("/sys/fs/cgroupx/a").is_none());
    assert!(cgroup_path("/tmp/a").is_none());
}

#[hegel::test]
fn events_and_membership_parse_exactly(tc: TestCase) {
    let value = tc.draw(gs::booleans());
    let frozen = tc.draw(gs::booleans());
    let events = format!(
        "populated {}\nfrozen {}\n",
        u8::from(value),
        u8::from(frozen)
    );
    assert_eq!(populated(&events), Some(value));
    assert_eq!(populated("frozen 0\n"), None);
    let pid = tc.draw(gs::integers::<u32>().min_value(1).max_value(PID_MAX));
    let other = if pid == PID_MAX { 1 } else { pid + 1 };
    assert!(member(&format!("{other}\n{pid}\n"), pid));
    assert!(!member(&format!("{other}\n"), pid));
    assert!(!member(&format!("0{pid}\n"), pid));
}

#[test]
fn cli_requires_exactly_two_canonical_arguments() {
    let ok = [
        OsString::from("/sys/fs/cgroup/lilly.slice/a.service"),
        OsString::from("42"),
    ];
    assert_eq!(
        parse_cli(&ok),
        Some(Target {
            cgroup: PathBuf::from("/sys/fs/cgroup/lilly.slice/a.service"),
            pid: 42
        })
    );
    assert!(parse_cli(&ok[..1]).is_none());
    let extra = [ok[0].clone(), ok[1].clone(), OsString::from("x")];
    assert!(parse_cli(&extra).is_none());
}

/// Real kernel behaviour where the build environment exposes cgroup v2: watch
/// a child in this process's own cgroup and kill it. Skips (passes) when the
/// sandbox has no readable cgroup2 mount; the NixOS vm-watch test always runs it.
#[test]
fn a_killed_child_is_reported_exited_promptly() {
    let Some(cgroup) = own_cgroup() else { return };
    let mut child = std::process::Command::new("sleep")
        .arg("30")
        .spawn()
        .expect("sleep");
    let target = Target {
        cgroup,
        pid: child.id(),
    };
    // The kept-open peer stands in for Lilly's port: no EOF, no input.
    let (parent_read, _parent_write) = std::os::unix::net::UnixStream::pair().expect("pair");
    let handle = std::thread::spawn(move || {
        let mut out = Vec::new();
        let outcome = watch_with(&target, &mut out, &parent_read);
        (outcome, out)
    });
    std::thread::sleep(std::time::Duration::from_millis(200));
    let started = std::time::Instant::now();
    child.kill().expect("kill");
    let _ = child.wait();
    let (outcome, out) = handle.join().expect("watcher");
    assert_eq!(outcome, Outcome::Exited);
    assert_eq!(out, b"armed\n");
    assert!(started.elapsed() < std::time::Duration::from_millis(500));
}

fn own_cgroup() -> Option<PathBuf> {
    let text = std::fs::read_to_string("/proc/self/cgroup").ok()?;
    let relative = text.lines().find_map(|line| line.strip_prefix("0::"))?;
    let path = cgroup_path(&format!("/sys/fs/cgroup{relative}"))?;
    std::fs::read_to_string(path.join("cgroup.procs")).ok()?;
    std::fs::read_to_string(path.join("cgroup.events")).ok()?;
    Some(path)
}

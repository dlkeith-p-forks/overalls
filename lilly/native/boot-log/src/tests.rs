use super::*;
use hegel::generators as gs;
use hegel::TestCase;
use std::ffi::OsStr;
use std::time::Duration;

/// @cc [owner:ghuntley,label:verification] hegel-boot-log-selector-oracle
/// Generated argument vectors MUST be classified by the independent selector
/// spec: exactly an absolute log path and absolute command, plus extra argv.
#[hegel::test]
fn cli_selector_matches_independent_oracle(tc: TestCase) {
    let alphabet = [
        "",
        "/",
        "/log",
        "log",
        "relative",
        "/usr/bin/vm",
        "vm",
        "/x y",
    ];
    let length = tc.draw(gs::integers::<usize>().min_value(0).max_value(6));
    let words: Vec<String> = (0..length)
        .map(|_| tc.draw(gs::sampled_from(&alphabet)).to_string())
        .collect();
    let ok = words.len() >= 2 && words[0].starts_with('/') && words[1].starts_with('/');
    match (
        parse_cli(&words.iter().map(OsString::from).collect::<Vec<_>>()),
        ok,
    ) {
        (None, false) => {}
        (Some(request), true) => {
            assert_eq!(request.log.as_os_str(), OsStr::new(words[0].as_str()));
            assert_eq!(request.program.as_os_str(), OsStr::new(words[1].as_str()));
            let rest: Vec<String> = request
                .arguments
                .iter()
                .map(|arg| arg.to_string_lossy().into_owned())
                .collect();
            assert_eq!(rest, words[2..].to_vec());
        }
        (parsed, ok) => panic!("selector diverged from oracle: {parsed:?} ok={ok}"),
    }
}

#[hegel::test]
fn drain_retains_exactly_the_bounded_prefix(tc: TestCase) {
    use std::io::Write as _;
    let size = tc.draw(hegel::one_of!(
        gs::integers::<usize>().min_value(0).max_value(4096),
        gs::integers::<usize>()
            .min_value(65530)
            .max_value(65536 + 6),
        gs::integers::<usize>()
            .min_value(BOOT_LOG_LIMIT - 66)
            .max_value(BOOT_LOG_LIMIT + 66),
        gs::integers::<usize>()
            .min_value(BOOT_LOG_LIMIT)
            .max_value(BOOT_LOG_LIMIT * 3),
    ));
    let seed = tc.draw(gs::integers::<u64>());
    let pattern = move |index: usize| ((index as u64).wrapping_mul(2654435761) ^ seed) as u8;

    let (reader, writer) = pipe_with(PipeFlags::CLOEXEC).expect("pipe");
    let expected: Vec<u8> = (0..size).map(pattern).collect();
    let writer_bytes = expected.clone();
    let writer_thread = std::thread::spawn(move || {
        let mut file = std::fs::File::from(writer);
        file.write_all(&writer_bytes).expect("write side");
    });
    let directory = tempfile::tempdir().expect("fixture directory");
    let path = directory.path().join("boot.log.raw");
    let mut output = std::fs::File::create(&path).expect("log file");
    let fixed = Duration::from_millis(1234);
    assert_eq!(drain(&reader, &mut output, &|| fixed), Drained::Complete);
    writer_thread.join().expect("writer joined");
    let kept = std::fs::read(&path).expect("kept bytes");
    let stamped = oracle_stamp(&expected, fixed);
    assert_eq!(kept.len(), stamped.len().min(BOOT_LOG_LIMIT));
    assert_eq!(kept, stamped[..stamped.len().min(BOOT_LOG_LIMIT)]);
}

/// Independent line-splitting oracle for boot-log-line-timestamps: split on
/// CR/LF terminators and prefix every non-empty segment.
fn oracle_stamp(input: &[u8], now: Duration) -> Vec<u8> {
    let prefix = format!("[+{}.{:03}] ", now.as_secs(), now.subsec_millis());
    let mut out = Vec::new();
    let mut segment_start = true;
    for &byte in input {
        let terminator = byte == b'\n' || byte == b'\r';
        if segment_start && !terminator {
            out.extend_from_slice(prefix.as_bytes());
        }
        segment_start = terminator;
        out.push(byte);
    }
    out
}

/// Strip every `[+S.mmm] ` that the stamper inserted, given its exact text.
fn strip_prefix(stamped: &[u8], now: Duration) -> Vec<u8> {
    let prefix = format!("[+{}.{:03}] ", now.as_secs(), now.subsec_millis());
    let mut out = Vec::new();
    let mut index = 0;
    let mut line_start = true;
    while index < stamped.len() {
        let byte = stamped[index];
        let terminator = byte == b'\n' || byte == b'\r';
        if line_start && !terminator {
            assert!(
                stamped[index..].starts_with(prefix.as_bytes()),
                "missing prefix at line start"
            );
            index += prefix.len();
            line_start = false;
            continue;
        }
        line_start = terminator;
        out.push(byte);
        index += 1;
    }
    out
}

fn console_bytes(tc: &TestCase, max: usize) -> Vec<u8> {
    let alphabet: [u8; 6] = *b"aZ \n\r[";
    let length = tc.draw(gs::integers::<usize>().min_value(0).max_value(max));
    (0..length)
        .map(|_| tc.draw(gs::sampled_from(&alphabet)))
        .collect()
}

#[test]
fn prefix_format_is_seconds_and_truncated_milliseconds() {
    for (duration, text) in [
        (Duration::ZERO, "[+0.000] "),
        (Duration::from_micros(1_999), "[+0.001] "),
        (Duration::from_millis(6_412), "[+6.412] "),
        (
            Duration::from_secs(3_725) + Duration::from_nanos(999_999_999),
            "[+3725.999] ",
        ),
    ] {
        let mut out = Vec::new();
        push_prefix(duration, &mut out);
        assert_eq!(out, text.as_bytes());
    }
}

#[test]
fn crlf_and_redraws_carry_one_prefix_per_visible_line() {
    let mut stamper = Stamper::new();
    let mut out = Vec::new();
    stamper.feed(b"Linux\r\n\r\nsystemd\rredraw\n", Duration::ZERO, &mut out);
    assert_eq!(
        out,
        b"[+0.000] Linux\r\n\r\n[+0.000] systemd\r[+0.000] redraw\n".to_vec()
    );
    assert_eq!(stamper.state(), LineState::LineStart);
}

#[test]
fn partial_line_keeps_its_first_read_timestamp() {
    let mut stamper = Stamper::new();
    let mut out = Vec::new();
    stamper.feed(b"Startup ", Duration::from_millis(100), &mut out);
    assert_eq!(stamper.state(), LineState::MidLine);
    stamper.feed(b"finished\nnext", Duration::from_millis(250), &mut out);
    assert_eq!(out, b"[+0.100] Startup finished\n[+0.250] next".to_vec());
}

/// @cc [owner:ghuntley,label:verification] hegel-boot-log-chunking-oracle
/// Arbitrary chunkings of generated console bytes MUST stamp identically to
/// the whole buffer and to the independent line oracle for one clock reading,
/// and stripping the prefixes MUST recover the input exactly.
#[hegel::test]
fn stamping_is_chunking_independent(tc: TestCase) {
    let input = console_bytes(&tc, 512);
    let now = Duration::from_millis(tc.draw(gs::integers::<u64>().max_value(10_000_000)));
    let mut whole = Vec::new();
    Stamper::new().feed(&input, now, &mut whole);
    let mut chunked = Vec::new();
    let mut stamper = Stamper::new();
    let mut rest: &[u8] = &input;
    while !rest.is_empty() {
        let size = tc.draw(gs::integers::<usize>().min_value(1).max_value(rest.len()));
        let (head, tail) = rest.split_at(size);
        stamper.feed(head, now, &mut chunked);
        rest = tail;
    }
    assert_eq!(chunked, whole);
    assert_eq!(whole, oracle_stamp(&input, now));
    assert_eq!(strip_prefix(&whole, now), input);
}

/// The stamped retention MUST never exceed BOOT_LOG_LIMIT and MUST equal the
/// limit-truncated prefix of the unbounded stamped stream for any chunking.
#[hegel::test]
fn retention_is_the_bounded_prefix_of_the_stamped_stream(tc: TestCase) {
    let lines = tc.draw(gs::integers::<usize>().min_value(0).max_value(4));
    let line_length = tc.draw(hegel::one_of!(
        gs::integers::<usize>().min_value(0).max_value(64),
        gs::integers::<usize>()
            .min_value(BOOT_LOG_LIMIT / 4)
            .max_value(BOOT_LOG_LIMIT / 2 + 64),
    ));
    let mut input = Vec::new();
    for _ in 0..lines {
        input.extend(std::iter::repeat_n(b'x', line_length));
        input.push(b'\n');
    }
    input.extend(console_bytes(&tc, 64));
    let now = Duration::from_millis(42);
    let mut retention = Retention::new();
    let mut kept = Vec::new();
    let mut rest: &[u8] = &input;
    while !rest.is_empty() {
        let size = tc.draw(
            gs::integers::<usize>()
                .min_value(1)
                .max_value(rest.len().min(65536)),
        );
        let (head, tail) = rest.split_at(size);
        kept.extend_from_slice(retention.admit(head, now));
        assert!(retention.retained() <= BOOT_LOG_LIMIT);
        rest = tail;
    }
    let stamped = oracle_stamp(&input, now);
    assert_eq!(kept.len(), retention.retained());
    assert_eq!(kept, stamped[..stamped.len().min(BOOT_LOG_LIMIT)]);
}

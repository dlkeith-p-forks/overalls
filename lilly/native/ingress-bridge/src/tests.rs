use super::*;
use hegel::generators as gs;
use hegel::TestCase;

/// The independent command-line specification.
fn oracle(words: &[String]) -> Option<(i32, i32, Option<u32>)> {
    let strict = |word: &str, low: u64, high: u64| -> Option<u64> {
        let canonical = !word.is_empty()
            && word.bytes().all(|byte| byte.is_ascii_digit())
            && !(word.len() > 1 && word.starts_with('0'));
        let value: u64 = if canonical {
            word.parse().ok()?
        } else {
            return None;
        };
        (low..=high).contains(&value).then_some(value)
    };
    let (client, guest, uid) = match words {
        [client, guest] => (client, guest, None),
        [client, guest, uid] => (client, guest, Some(strict(uid, 1, 4_294_967_294)? as u32)),
        _ => return None,
    };
    let client = strict(client, 3, 1023)? as i32;
    let guest = strict(guest, 3, 1023)? as i32;
    (client != guest).then_some((client, guest, uid))
}

fn word(tc: &TestCase) -> String {
    let choice = tc.draw(gs::integers::<u8>().max_value(5));
    match choice {
        0 => tc.draw(gs::integers::<u16>().max_value(1100)).to_string(),
        1 => tc.draw(gs::integers::<u64>()).to_string(),
        2 => format!("0{}", tc.draw(gs::integers::<u16>().max_value(99))),
        3 => String::new(),
        4 => "-".to_string(),
        _ => format!("{} ", tc.draw(gs::integers::<u16>().max_value(1100))),
    }
}

/// @cc [owner:ghuntley,label:verification] bridge-cli-oracle
/// parse_cli MUST agree with an independent specification of the command line
/// on arbitrary word lists, including leading zeros, padding and bounds.
#[hegel::test]
fn command_line_matches_the_independent_oracle(tc: TestCase) {
    let count = tc.draw(gs::integers::<usize>().max_value(4));
    let words: Vec<String> = (0..count).map(|_| word(&tc)).collect();
    let arguments: Vec<OsString> = words.iter().map(OsString::from).collect();
    let parsed = parse_cli(&arguments).map(|request| (request.client, request.guest, request.uid));
    assert_eq!(parsed, oracle(&words));
}

/// @cc [owner:ghuntley,label:verification] bridge-direction-model
/// Over any interleaving of partial reads, partial writes and end of stream,
/// a direction MUST hold exactly the bytes read minus the bytes written,
/// never exceed its window, stop reading after end of stream, and report
/// drained exactly when end of stream was seen with nothing pending.
#[hegel::test]
fn direction_accounts_for_every_byte(tc: TestCase) {
    let mut direction = Direction::default();
    let (mut read, mut written, mut eof) = (0_usize, 0_usize, false);
    let steps = tc.draw(gs::integers::<usize>().max_value(64));
    for _ in 0..steps {
        if tc.draw(gs::booleans()) && direction.wants_read() {
            let count = tc.draw(gs::integers::<usize>().max_value(direction.room()));
            direction.read(count);
            if count == 0 {
                eof = true;
            } else {
                read += count;
            }
        } else if direction.wants_write() {
            let count = tc.draw(
                gs::integers::<usize>()
                    .min_value(1)
                    .max_value(direction.pending),
            );
            direction.wrote(count);
            written += count;
        }
        assert_eq!(direction.pending, read - written);
        assert!(direction.pending <= WINDOW);
        assert_eq!(direction.eof, eof);
        assert!(!(eof && direction.wants_read()));
        assert_eq!(direction.drained(), eof && read == written);
    }
    assert_eq!(finished(&direction), direction.drained());
    assert_eq!(half_close_due(&direction), direction.drained());
}

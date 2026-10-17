use super::*;
use hegel::generators as gs;
use hegel::TestCase;

fn good_key(tc: &TestCase) -> String {
    let alphabet: Vec<char> = ('A'..='Z')
        .chain('a'..='z')
        .chain('0'..='9')
        .chain(['+', '/', '='])
        .collect();
    (0..68)
        .map(|_| tc.draw(gs::sampled_from(&alphabet)))
        .collect()
}

/// @cc [owner:ghuntley,label:verification] hegel-export-record-roundtrip
/// Generated (key, command) pairs MUST round-trip which preserves equality,
/// and each decoded record keeps exact fields, byte for byte.
#[hegel::test]
fn record_roundtrip_is_exact(tc: TestCase) {
    let key = good_key(&tc);
    let max: usize = tc.draw(
        gs::integers::<usize>()
            .min_value(1)
            .max_value(COMMAND_BYTES - 1),
    );
    let command: String = (0..max)
        .map(|_| {
            let code = tc.draw(gs::integers::<u8>().min_value(32).max_value(126));
            char::from(code)
        })
        .collect();
    let request = build(&key, &command).expect("constructed record");
    assert_eq!(decode(&encode(&request)), Some(request));
}

/// @cc [owner:ghuntley,label:verification] hegel-export-record-scrutiny
/// Generated perturbations (magic, sizes, padding, charsets) MUST be rejected
/// exactly when the independent model says so.
#[hegel::test]
fn record_refusal_matrix_follows_the_oracle(tc: TestCase) {
    let key = good_key(&tc);
    let command = "zfs send --props".to_string();
    let request = build(&key, &command).expect("formed record");
    let mut wire = encode(&request);
    let slot = tc.draw(gs::sampled_from(&[
        "magic",
        "key_size",
        "command_size",
        "key_content",
        "command_content",
        "key_padding",
        "command_padding",
        "clean",
    ]));
    let mut expected = true;
    match slot {
        "magic" => {
            wire[2] ^= 0x01;
            expected = false;
        }
        "key_size" => {
            wire[5] ^= 0x02;
            expected = false;
        }
        "command_size" => {
            let size = command.len() + 1;
            wire[6..8].copy_from_slice(&(size as u16).to_be_bytes());
            expected = false;
        }
        "key_content" => {
            wire[9] = b'*';
            expected = false;
        }
        "command_content" => {
            wire[9 + KEY_BYTES] = 0x1f;
            expected = false;
        }
        "key_padding" => {
            wire[8 + 68] = 1;
            expected = false;
        }
        "command_padding" => {
            wire[9 + KEY_BYTES + command.len()] = 1;
            expected = false;
        }
        _ => {}
    }
    let _ = expected;
    assert_eq!(decode(&wire).is_some(), expected, "slot {slot}");
}

#[hegel::test]
fn selector_and_environment_parsing_match_the_spec(tc: TestCase) {
    // bridge: [socket, key]; serve: [account, worker...] with 1..=31 argv.
    let long = "a".repeat(200);
    let opts = ["", "/", "x", "/socket", &long][0];
    let _ = opts;
    let socket = tc.draw(gs::sampled_from(&["/s/ok.sock", "relative.sock", "", "/x"]));
    let key68 = good_key(&tc);
    let key_maybe: String = if tc.draw(gs::booleans()) {
        key68.clone()
    } else {
        tc.draw(gs::sampled_from(&[
            "",
            "short",
            "non-ascii-🔥",
            "bad*chars",
        ]))
        .to_string()
    };
    let command = if tc.draw(gs::booleans()) {
        "printed line".to_string()
    } else {
        "illegal\nnewline".to_string()
    };
    let bridge = parse_bridge(
        &[OsString::from(socket), OsString::from(key_maybe.clone())],
        Some(OsStr::new(&command)),
    );
    let expected = socket.starts_with('/')
        && key_maybe.len() == 68
        && key_bytes_ok(key_maybe.as_bytes())
        && !command.is_empty()
        && command.len() < COMMAND_BYTES
        && command.bytes().all(|byte| (32..=126).contains(&byte));
    assert_eq!(bridge.is_some(), expected);
    if let Some(req) = bridge {
        assert_eq!(req.command, command);
    }
    let serve_ok = parse_serve(&[OsString::from("lilly-transfer"), OsString::from("/worker")]);
    assert_eq!(
        serve_ok.map(|s| s.account),
        Some("lilly-transfer".to_string())
    );
    assert_eq!(parse_serve(&[OsString::from("acct")]), None);
    assert_eq!(
        parse_serve(&[OsString::from("acct"), OsString::from("relative")]),
        None
    );
}

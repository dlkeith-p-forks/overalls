use super::*;
use hegel::generators as gs;
use hegel::TestCase;

fn good_uuid(tc: &TestCase) -> String {
    let mut text = String::with_capacity(36);
    for index in 0..36 {
        if matches!(index, 8 | 13 | 18 | 23) {
            text.push('-');
        } else {
            let digit = tc.draw(gs::integers::<u8>().min_value(0).max_value(15));
            text.push(char::from_digit(digit.into(), 16).expect("hex digit"));
        }
    }
    text
}

fn spec_expect(arguments: &[&str]) -> bool {
    let [lock, intent, placement_id, epoch, generation, program, ..] = arguments else {
        return false;
    };
    let absolute_ok = [lock, intent, program]
        .iter()
        .all(|value| value.starts_with('/'));
    let placement_ok = placement_id.len() == 36
        && placement_id.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                matches!(byte, b'0'..=b'9' | b'a'..=b'f')
            }
        });
    let counter_ok = |value: &str| {
        !value.is_empty()
            && !value.starts_with('0')
            && value.bytes().all(|byte| byte.is_ascii_digit())
            && value
                .parse::<u64>()
                .is_ok_and(|number| (1..=u64::try_from(i64::MAX).unwrap()).contains(&number))
    };
    absolute_ok && placement_ok && counter_ok(epoch) && counter_ok(generation)
}

/// @cc [owner:ghuntley,label:verification] hegel-launch-selector-oracle
/// Generated argument vectors MUST be classified by an independent selector
/// spec, and accepted selectors MUST preserve every field byte-for-byte.
#[hegel::test]
fn cli_selector_matches_independent_oracle(tc: TestCase) {
    let alphabet = [
        "", "/", "/lock", "/intent", "relative", "jailer", "/jailer", "shared",
    ];
    let length = tc.draw(gs::integers::<usize>().min_value(0).max_value(8));
    let mut words: Vec<String> = Vec::new();
    for _ in 0..length {
        words.push(tc.draw(gs::sampled_from(&alphabet)).to_string());
    }
    // Bias some draws into structurally valid prefix territory while retaining
    // corruption slots at every position.
    if words.len() >= 6 {
        if tc.draw(gs::booleans()) {
            words[0] = "/lock".to_string();
        }
        if tc.draw(gs::booleans()) {
            words[1] = "/intent".to_string();
        }
        if tc.draw(gs::booleans()) {
            words[2] = good_uuid(&tc);
        }
        if tc.draw(gs::booleans()) {
            words[3] = tc
                .draw(
                    gs::integers::<u64>()
                        .min_value(1)
                        .max_value(i64::MAX as u64),
                )
                .to_string();
        }
        if tc.draw(gs::booleans()) {
            words[4] = tc
                .draw(
                    gs::integers::<u64>()
                        .min_value(1)
                        .max_value(i64::MAX as u64),
                )
                .to_string();
        }
        if tc.draw(gs::booleans()) {
            words[5] = "/jailer".to_string();
        }
    }
    let references: Vec<&str> = words.iter().map(String::as_str).collect();
    let arguments: Vec<OsString> = words.iter().map(OsString::from).collect();
    let expected = spec_expect(&references);
    match (parse_cli(&arguments), expected) {
        (None, false) => {}
        (Some(request), true) => {
            assert_eq!(request.lock.as_os_str(), OsStr::new(words[0].as_str()));
            assert_eq!(request.intent.as_os_str(), OsStr::new(words[1].as_str()));
            assert_eq!(request.placement, words[2]);
            assert_eq!(request.epoch.to_string(), words[3],);
            assert_eq!(request.generation.to_string(), words[4],);
            assert_eq!(request.program.as_os_str(), OsStr::new(words[5].as_str()));
            let rest: Vec<String> = request
                .arguments
                .iter()
                .map(|arg| arg.to_string_lossy().into_owned())
                .collect();
            assert_eq!(rest, words[6..].to_vec());
        }
        (parsed, expected) => panic!("selector diverged from oracle: {parsed:?} {expected}"),
    }
}

#[test]
fn intent_framing_edge_byte_positions() {
    let placement = b"01234567-89ab-4def-8123-456789abcdef";
    let epoch = 0x0102_0304_0506_0708_u64;
    let generation = 0x1112_1314_1516_1718_u64;
    let mut bytes = Vec::with_capacity(INTENT_BYTES);
    bytes.extend_from_slice(placement);
    bytes.extend_from_slice(&epoch.to_be_bytes());
    bytes.extend_from_slice(&generation.to_be_bytes());
    bytes.push(RUNNING_STATE);
    assert_eq!(bytes.len(), INTENT_BYTES);
    let intent = Intent {
        placement: *placement,
        epoch,
        generation,
        state: RUNNING_STATE,
    };
    let directory = tempfile::tempdir().expect("fixture directory");
    let path = directory.path().join("intent");
    std::fs::write(&path, &bytes).expect("staged intent");
    let fd: OwnedFd = std::fs::File::open(&path).expect("opened intent").into();
    assert_eq!(read_intent(&fd), Ok(intent));
    let short: OwnedFd = std::fs::File::open({
        std::fs::write(directory.path().join("short"), &bytes[..52]).expect("staged short");
        directory.path().join("short")
    })
    .expect("opened short")
    .into();
    assert_eq!(read_intent(&short), Err(IntentError::Framing));
}

/// @cc [owner:ghuntley,label:verification] hegel-launch-current-predicate
/// Generated intent/request pairs MUST authorize exec only when placement,
/// epoch, generation and the running-state byte ALL match, byte for byte.
#[hegel::test]
fn current_generation_predicate_is_exact(tc: TestCase) {
    let uuid = good_uuid(&tc);
    let epoch = tc.draw(
        gs::integers::<u64>()
            .min_value(1)
            .max_value(i64::MAX as u64),
    );
    let generation = tc.draw(
        gs::integers::<u64>()
            .min_value(1)
            .max_value(i64::MAX as u64),
    );
    let mut request = Request {
        lock: PathBuf::from("/lock"),
        intent: PathBuf::from("/intent"),
        placement: uuid.clone(),
        epoch,
        generation,
        program: PathBuf::from("/jailer"),
        arguments: Vec::new(),
    };
    let mut bytes: [u8; 36] = uuid.as_bytes().try_into().expect("uuid bytes");
    let mut intent = Intent {
        placement: bytes,
        epoch,
        generation,
        state: RUNNING_STATE,
    };
    assert!(current(&intent, &request));
    let field = tc.draw(gs::integers::<u8>().min_value(0).max_value(3));
    match field {
        0 => {
            let position = tc.draw(gs::integers::<usize>().min_value(0).max_value(35));
            bytes[position] = match bytes[position] {
                b'-' => b'-',
                b'f' => b'e',
                value => value + 1,
            };
            intent.placement = bytes;
        }
        1 => {
            request.epoch = epoch.wrapping_add(
                tc.draw(
                    gs::integers::<u64>()
                        .min_value(1)
                        .max_value(u16::MAX as u64),
                ),
            )
        }
        2 => {
            request.generation = generation.wrapping_add(
                tc.draw(
                    gs::integers::<u64>()
                        .min_value(1)
                        .max_value(u16::MAX as u64),
                ),
            )
        }
        _ => intent.state = tc.draw(gs::integers::<u8>()),
    }
    let placed_same = intent.placement[..] == request.placement.as_bytes()[..];
    let expected = placed_same
        && intent.epoch == request.epoch
        && intent.generation == request.generation
        && intent.state == RUNNING_STATE;
    assert_eq!(current(&intent, &request), expected);
}

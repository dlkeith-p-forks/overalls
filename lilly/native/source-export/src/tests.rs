use super::*;
use hegel::generators as gs;
use hegel::TestCase;

/// @cc [owner:ghuntley,label:verification] hegel-source-export-selectors
/// Generated leases and argv shapes MUST classify against the independent
/// spec: positive decimal within 1..=300000, no leading zero, absolute paths,
/// sender arity and total byte span as the C helper measured them.
#[hegel::test]
fn lease_and_selector_match_independent_spec(tc: TestCase) {
    let lease_candidates = [
        "0",
        "00",
        "01",
        "1",
        "1000",
        "299999",
        "300000",
        "300001",
        "x",
        "",
        "-1",
        "300000 ",
        "3000000",
        "18446744073709551615123",
    ];
    let path_candidates = ["", "/", "/lock", "/sender", "relative", "/x y"];
    let lease = tc.draw(gs::sampled_from(&lease_candidates)).to_string();
    let lock = tc.draw(gs::sampled_from(&path_candidates)).to_string();
    let sender = tc.draw(gs::sampled_from(&path_candidates)).to_string();
    let rest_count = tc.draw(gs::integers::<usize>().min_value(0).max_value(130));
    let arguments: Vec<OsString> = [lock, lease, sender]
        .into_iter()
        .map(OsString::from)
        .chain((0..rest_count).map(|index| OsString::from(format!("arg{index}"))))
        .collect();

    let lease_spec = |text: &str| {
        !text.is_empty()
            && !text.starts_with('0')
            && text.bytes().all(|byte| byte.is_ascii_digit())
            && text
                .parse::<u64>()
                .is_ok_and(|value| (1..=300_000).contains(&value))
    };
    let argv_spec = arguments.len() >= 3 && arguments.len() <= 130;
    let expected = argv_spec
        && arguments[0].as_os_str().as_bytes().starts_with(b"/")
        && arguments[2].as_os_str().as_bytes().starts_with(b"/")
        && lease_spec(&arguments[1].to_string_lossy());

    match (parse_cli(&arguments), expected) {
        (None, false) => {}
        (Some(request), true) => {
            assert_eq!(request.lock.as_os_str(), arguments[0].as_os_str());
            assert_eq!(request.sender.as_os_str(), arguments[2].as_os_str());
            assert_eq!(request.arguments.len(), arguments.len() - 3);
        }
        (parsed, expected) => panic!("selector diverged: {parsed:?} {expected}"),
    }
}

/// @cc [owner:ghuntley,label:verification] hegel-source-export-renew-or-revoke
/// Only a valid `L<millis>` line renews; every other byte shape revokes.
#[hegel::test]
fn control_frames_renew_or_revoke_exactly(tc: TestCase) {
    let candidates: Vec<Vec<u8>> = vec![
        b"L1".to_vec(),
        b"L300000".to_vec(),
        b"L300001".to_vec(),
        b"L0".to_vec(),
        b"L".to_vec(),
        b"X".to_vec(),
        b"".to_vec(),
        b" L1000".to_vec(),
        vec![b'L', 0x80, b'1'],
    ];
    let frame = tc.draw(gs::sampled_from(&candidates)).clone();
    let expected = match frame.as_slice() {
        [b'L', rest @ ..] => std::str::from_utf8(rest).ok().and_then(|text| {
            let value: u32 = text.parse().ok()?;
            ((1..=300_000).contains(&value)
                && !text.is_empty()
                && !text.starts_with('0')
                && text.bytes().all(|byte| byte.is_ascii_digit()))
            .then_some(value)
        }),
        _ => None,
    };
    assert_eq!(parse_control(&frame), expected.map(Control::Renew));
}

use super::*;
use hegel::generators as gs;
use hegel::TestCase;

/// @cc [owner:ghuntley,label:verification] hegel-token-envelope-oracle
/// Generated envelopes MUST match the independent spec exactly: `1-` prefix,
/// ≤8192 bytes, two ≤16-digit lowercase hex fields (second within 1..16384),
/// then an even lowercase-hex payload.
#[hegel::test]
fn bounded_matches_independent_spec(tc: TestCase) {
    let size_class = tc.draw(gs::sampled_from(&[0usize, 1, 2, 3, 15, 16, 17, 8190]));
    let fill = "0".repeat(size_class);
    let variants = [
        format!("1-{fill}"),
        format!("1-a-{fill}"),
        format!("1-a-1-{fill}"),
        format!("1-a-1-{fill}A"),
        format!("1-a-4000-{fill}"),
        format!("1-A-1-{fill}"),
        format!("2-a-1-{fill}"),
        format!("1-a-0-{fill}"),
        format!("1-a-4001-{fill}"),
        format!("1--1-{fill}"),
        format!("1-a-1-{fill}0"),
        String::from_utf8(b"1-a-1-".to_vec()).unwrap() + &"ff".repeat(size_class / 2),
    ];
    let token = tc.draw(gs::sampled_from(&variants)).to_string();
    let expected = (|| {
        if token.len() > TOKEN_MAX_BYTES || !token.starts_with("1-") {
            return false;
        }
        let body = &token[2..];
        let look = |segment: &str| {
            !segment.is_empty()
                && segment.len() <= 16
                && segment
                    .bytes()
                    .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        };
        let Some(first_dash) = body.find('-') else {
            return false;
        };
        if !look(&body[..first_dash]) {
            return false;
        }
        let rest = &body[first_dash + 1..];
        let Some(second_dash) = rest.find('-') else {
            return false;
        };
        if !look(&rest[..second_dash]) {
            return false;
        }
        let unpacked_text = &rest[..second_dash];
        let unpacked = u64::from_str_radix(unpacked_text, 16).expect("oracle hex");
        if unpacked == 0 || unpacked > 16384 {
            return false;
        }
        let payload = &rest[second_dash + 1..];
        !payload.is_empty()
            && payload.len().is_multiple_of(2)
            && payload
                .bytes()
                .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    })();
    assert_eq!(bounded(&token), expected, "token {token:?}");
}

/// @cc [owner:ghuntley,label:verification] hegel-lineage-exact-matrix
/// Generated nv-pair lists MUST be classified by the independent lineage
/// spec: the five required keys once each, no unknowns, exact values, a
/// zero-or-absent fromguid, and capability booleans only from the permit set.
#[hegel::test]
fn lineage_matches_the_spec_matrix(tc: TestCase) {
    let names = [
        "toname",
        "object",
        "offset",
        "bytes",
        "toguid",
        "fromguid",
        "largeblockok",
        "embedok",
        "compressok",
        "foreign",
        "rawok",
    ];
    let mut pairs: Vec<Pair> = Vec::new();
    let len = tc.draw(gs::integers::<usize>().min_value(0).max_value(10));
    for _ in 0..len {
        let name = tc.draw(gs::sampled_from(&names)).to_string();
        let roll = tc.draw(gs::integers::<u8>().min_value(0).max_value(3));
        pairs.push(match (roll, name.as_str()) {
            (_, "toname") => Pair::Str(
                name,
                tc.draw(gs::sampled_from(&["tank/a@b", "tank/b@c"]))
                    .to_string(),
            ),
            (0, "object" | "offset" | "bytes" | "toguid" | "fromguid") => Pair::Uint(
                name,
                tc.draw(gs::integers::<u64>().min_value(1).max_value(99)),
            ),
            (1, "object" | "offset" | "bytes" | "toguid" | "fromguid") => Pair::Uint(
                name,
                tc.draw(gs::integers::<u64>().min_value(100).max_value(199)),
            ),
            (2, "fromguid") => Pair::Uint(name, 0),
            (_, "largeblockok" | "embedok" | "compressok") => Pair::Bool(name),
            _ => Pair::Other(name, 0),
        });
    }
    let name_it = "tank/a@b";
    let to = 50_u64;
    let expected = oracle(&pairs, name_it, to);
    assert_eq!(matches(&pairs, name_it, to), expected);
}

fn oracle(pairs: &[Pair], name: &str, to: u64) -> bool {
    let mut seen = [false; 9];
    let mut actual_to = None;
    let mut actual_from = None;
    for pair in pairs {
        let pair_name = match pair {
            Pair::Str(n, _) | Pair::Uint(n, _) | Pair::Bool(n) | Pair::Other(n, _) => n.as_str(),
        };
        let Some(index) = [
            "toname",
            "object",
            "offset",
            "bytes",
            "toguid",
            "fromguid",
            "largeblockok",
            "embedok",
            "compressok",
        ]
        .iter()
        .position(|k| *k == pair_name) else {
            return false;
        };
        if seen[index] {
            return false;
        }
        seen[index] = true;
        match (index, pair) {
            (0, Pair::Str(_, value)) if value == name => {}
            (0, _) => return false,
            (1..=5, Pair::Uint(_, value)) => {
                if index == 4 {
                    actual_to = Some(*value);
                }
                if index == 5 {
                    actual_from = Some(*value);
                }
            }
            (1..=5, _) => return false,
            (6..=8, Pair::Bool(_)) => {}
            (6..=8, _) => return false,
            _ => return false,
        }
    }
    seen[..5].iter().all(|s| *s) && actual_to == Some(to) && actual_from.unwrap_or(0) == 0
}

/// @cc [owner:ghuntley,label:verification] cli-parentless-arity
/// The CLI MUST accept exactly snapshot name, nonzero to GUID and bounded token;
/// the retired four-argument form carrying a parent GUID MUST be a usage failure.
#[test]
fn cli_accepts_only_the_parentless_form() {
    let args = |values: &[&str]| -> Vec<OsString> { values.iter().map(OsString::from).collect() };
    assert_eq!(
        parse_cli(&args(&["tank/vm@lilly-b", "123", "1-1-100-aabb"])),
        Some(Request {
            name: "tank/vm@lilly-b".to_string(),
            to: 123,
            token: "1-1-100-aabb".to_string(),
        })
    );
    for rejected in [
        args(&["tank/vm@lilly-b", "123", "0", "1-1-100-aabb"]),
        args(&["tank/vm@lilly-b", "0", "1-1-100-aabb"]),
        args(&["tank/vm@lilly-b", "123"]),
    ] {
        assert_eq!(parse_cli(&rejected), None);
    }
}

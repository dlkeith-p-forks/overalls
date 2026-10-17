use super::*;
use hegel::generators as gs;
use hegel::TestCase;

/// @cc [owner:ghuntley,label:verification] hegel-side-classifier-lattice
/// The outcome lattice is fully enumerable: five side pairs must terminate and
/// only the jointly-observed pairings resolve.
#[hegel::test]
fn outcome_classifier_matches_the_closed_lattice(_tc: TestCase) {
    use Side::{Failed, Running, Succeeded};
    assert_eq!(Failed.classify(Failed), Some(7));
    assert_eq!(Failed.classify(Running), Some(5));
    assert_eq!(Failed.classify(Succeeded), Some(5));
    assert_eq!(Running.classify(Failed), Some(6));
    assert_eq!(Succeeded.classify(Failed), Some(6));
    assert_eq!(Succeeded.classify(Succeeded), Some(0));
    assert_eq!(Running.classify(Running), None);
    assert_eq!(Running.classify(Succeeded), None);
    assert_eq!(Succeeded.classify(Running), None);
    let states = [Running, Succeeded, Failed];
    for first in states {
        for second in states {
            let expected = match (first, second) {
                (Failed, Failed) => Some(7),
                (Failed, _) => Some(5),
                (_, Failed) => Some(6),
                (Succeeded, Succeeded) => Some(0),
                _ => None,
            };
            assert_eq!(first.classify(second), expected);
        }
    }
}

/// @cc [owner:ghuntley,label:verification] hegel-transfer-selector-oracle
/// Generated argv vectors MUST classify against the independent selector spec:
/// absolute lock/producer/consumer heads, bounded counts and byte span.
#[hegel::test]
fn cli_selector_matches_independent_oracle(tc: TestCase) {
    let base = ["/lock", "/prod/0", "/cons/0", "1000", "1"];
    let argc = tc.draw(gs::integers::<usize>().min_value(0).max_value(10));
    let mut words: Vec<OsString> = Vec::new();
    for index in 0..argc {
        let candidate = if index < base.len() && tc.draw(gs::booleans()) {
            base[index].to_string()
        } else {
            tc.draw(gs::sampled_from(&[
                "", "/", "x", "0", "999", "1000", "86400000", "86400001", "129", "/prod", "/cons",
                "otra",
            ]))
            .to_string()
        };
        words.push(OsString::from(candidate));
    }
    let expected: Option<()> = (|| {
        let [lock, timeout, producers, rest @ ..] = words.as_slice() else {
            return None;
        };
        let t = number(timeout, 1000, 86_400_000)?;
        let p = number(producers, 1, PRODUCER_ARGS_LIMIT as i64)?;
        let split = usize::try_from(p).ok()?;
        if rest.len() < split + 1 || rest.len() - split > CONSUMER_ARGS_LIMIT {
            return None;
        }
        let producer = &rest[..split];
        let consumer = &rest[split..];
        if t == 0 || consumer.is_empty() {
            return None;
        }
        if !lock.as_os_str().as_bytes().starts_with(b"/")
            || !producer[0].as_os_str().as_bytes().starts_with(b"/")
            || !consumer[0].as_os_str().as_bytes().starts_with(b"/")
        {
            return None;
        }
        if producer
            .iter()
            .chain(consumer.iter())
            .any(|a| a.is_empty() || a.as_os_str().as_bytes().contains(&0))
        {
            return None;
        }
        let total: usize = producer
            .iter()
            .chain(consumer.iter())
            .map(|a| a.as_os_str().as_bytes().len() + 1)
            .sum();
        if total > ARGV_TOTAL_LIMIT {
            return None;
        }
        Some(())
    })();
    match (parse_cli(&words), expected) {
        (None, None) => {}
        (Some(request), Some(())) => {
            assert_eq!(request.lock.as_os_str(), words[0].as_os_str());
            assert_eq!(
                request.timeout_ms,
                words[1]
                    .to_string_lossy()
                    .parse::<u64>()
                    .expect("drawn timeout")
            );
            assert_eq!(
                request.producer.len() + request.consumer.len(),
                words.len() - 4
            );
        }
        (parsed, expected) => panic!("diverged: parsed={parsed:?} expected={expected:?}"),
    }
}

/// @cc [owner:ghuntley,label:verification] hegel-transfer-progress-or-env
/// Generated env strings MUST classify via the independent env spec:
/// progress ∈ {absent, "0", "1"}, rate a decimal in 0..=1073741824 with no
/// leading zero; anything else is rejected (exit 64 through the caller).
#[hegel::test]
fn env_config_matches_independent_spec(tc: TestCase) {
    let progress_opts = ["0", "1", "yes", "", "00"];
    let rate_candidates = [
        "0",
        "1",
        "00",
        "1073741824",
        "1073741825",
        "x",
        "18446744073709551616",
    ];
    let progress = if tc.draw(gs::booleans()) {
        Some(tc.draw(gs::sampled_from(&progress_opts)).to_string())
    } else {
        None
    };
    let rate = if tc.draw(gs::booleans()) {
        Some(tc.draw(gs::sampled_from(&rate_candidates)).to_string())
    } else {
        None
    };
    let expected_progress = match progress.as_deref() {
        None => Some(false),
        Some("0") => Some(false),
        Some("1") => Some(true),
        _ => None,
    };
    let expected_rate = match rate.as_deref() {
        None => Some(0),
        Some(text) if !(text.is_empty() || text.len() > 1 && text.starts_with('0')) => {
            if text.bytes().all(|b| b.is_ascii_digit()) {
                text.parse::<u64>().ok().filter(|v| *v <= 1_073_741_824)
            } else {
                None
            }
        }
        _ => None,
    };
    match (expected_progress, expected_rate) {
        (Some(p), Some(r)) => {
            let config = parse_env(progress.as_deref(), rate.as_deref()).expect("accepted");
            assert_eq!(config.progress, p);
            assert_eq!(config.rate, r);
        }
        _ => assert_eq!(parse_env(progress.as_deref(), rate.as_deref()), None),
    }
}

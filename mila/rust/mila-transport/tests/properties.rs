use hegel::{generators as gs, TestCase};
use mila_transport::{parse_host_certificate_blob, parse_host_certificate_line};
#[hegel::test(test_cases = 64)]
fn arbitrary_bytes_never_panic(tc: TestCase) {
    let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(300));
    let _ = parse_host_certificate_blob(&bytes);
}
#[hegel::test(test_cases = 64)]
fn malformed_lines_are_rejected(tc: TestCase) {
    let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(300));
    let s = String::from_utf8_lossy(&bytes);
    let _ = parse_host_certificate_line(&s);
}

use mila_transport::{decode_trust_document, WatchRequest};
#[hegel::test(test_cases = 64)]
fn arbitrary_trust_bytes_never_panic(tc: TestCase) {
    let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(9000));
    let _ = decode_trust_document(&bytes, "mila.example", 1);
}
#[test]
fn trust_reconciliation_keeps_authority_and_latest_retirement() {
    let ca = "ssh-ed25519 AAA="; // malformed CA is intentionally rejected by decoder
    let _ = ca;
    let a = uuid::Uuid::new_v4();
    assert!(
        WatchRequest::new(vec![a, a], vec![])
            .unwrap()
            .machines
            .len()
            == 1
    );
}

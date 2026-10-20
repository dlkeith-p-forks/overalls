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

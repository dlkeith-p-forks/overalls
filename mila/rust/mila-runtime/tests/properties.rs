use hegel::{generators as gs, TestCase};
use mila_runtime::{MachineSnapshot, SnapshotMachine, MAX_SNAPSHOT_BYTES};
use mila_runtime::{PushEnvironment, PushProvider, PushRegistrationRequest};

#[hegel::test(test_cases = 64)]
fn arbitrary_bytes_never_panic(tc: TestCase) {
    let bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(2_000));
    let _ = MachineSnapshot::decode(&bytes, "control.example.test", None);
}

#[hegel::test(test_cases = 64)]
fn encoded_snapshots_round_trip(tc: TestCase) {
    let name_bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(32));
    let id_bytes = tc.draw(gs::vecs(gs::default::<u8>()).max_size(32));
    let name = String::from_utf8_lossy(&name_bytes).into_owned();
    let id = String::from_utf8_lossy(&id_bytes).into_owned();
    let machine = SnapshotMachine {
        id,
        name,
        desired_state: "running".into(),
        observed_state: None,
        pinned: false,
        owner: None,
        read: true,
        write: false,
        manage: false,
    };
    let snapshot = MachineSnapshot::new("control.example.test".into(), None, 10, vec![machine])
        .expect("valid");
    let encoded = snapshot.encode().expect("encode");
    assert!(encoded.len() <= MAX_SNAPSHOT_BYTES);
    assert_eq!(
        MachineSnapshot::decode(&encoded, "control.example.test", None).expect("decode"),
        snapshot
    );
}

#[hegel::test(test_cases = 64)]
fn arbitrary_registration_inputs_never_panic(tc: TestCase) {
    let token =
        String::from_utf8_lossy(&tc.draw(gs::vecs(gs::default::<u8>()).max_size(800))).into_owned();
    let app =
        String::from_utf8_lossy(&tc.draw(gs::vecs(gs::default::<u8>()).max_size(300))).into_owned();
    let host =
        String::from_utf8_lossy(&tc.draw(gs::vecs(gs::default::<u8>()).max_size(300))).into_owned();
    let _ = PushRegistrationRequest::new(
        PushProvider::Fcm,
        token,
        app,
        PushEnvironment::Production,
        host,
        None,
    );
}

#[test]
fn registration_restricts_origins_and_secrets() {
    let token = "a".repeat(32);
    let req = PushRegistrationRequest::new(
        PushProvider::Apns,
        token,
        "com.example.mila".into(),
        PushEnvironment::Production,
        "mila.example.test".into(),
        None,
    )
    .expect("valid");
    assert_eq!(PushProvider::Apns.origin(), "https://api.push.apple.com");
    assert!(!format!("{req:?}").contains("aaaa"));
    assert!(PushRegistrationRequest::new(
        PushProvider::Fcm,
        "a".repeat(32),
        "app".into(),
        PushEnvironment::Development,
        "mila.example.test".into(),
        None
    )
    .is_err());
    assert!(PushRegistrationRequest::new(
        PushProvider::Wns,
        "https://evil.example/channel".into(),
        "app".into(),
        PushEnvironment::Production,
        "mila.example.test".into(),
        Some("https://evil.example/channel".into())
    )
    .is_err());
}

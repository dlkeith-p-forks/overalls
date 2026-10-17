//! Independent host-local recorder; arguments contain reviewed paths and role only.

use overalls_otel_guest_receiver::{
    durable_slo::Source,
    request_recorder::{Config, Policy},
};
use std::path::PathBuf;

fn run() -> Result<(), ()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [source, state, socket, snapshot, mode, user, unit, seconds] = args.as_slice() else {
        return Err(());
    };
    let config = Config {
        source: Source::from_name(source).ok_or(())?,
        state: PathBuf::from(state),
        socket: PathBuf::from(socket),
        snapshot: PathBuf::from(snapshot),
        snapshot_mode: u32::from_str_radix(mode, 8).map_err(|_| ())?,
        policy: Policy {
            user: user.clone(),
            unit: unit.clone(),
        },
        deadline_ns: seconds
            .parse::<u64>()
            .map_err(|_| ())?
            .checked_mul(1_000_000_000)
            .ok_or(())?,
    };
    overalls_otel_guest_receiver::request_recorder::run(config).map_err(|refusal| {
        // The reason is a fixed vocabulary; it never carries paths or state.
        if let Ok(reason) = serde_json::to_string(&refusal) {
            eprintln!("{{\"event\":\"slo_recorder.refused\",\"reason\":{reason}}}");
        }
    })
}

fn main() {
    if run().is_err() {
        std::process::exit(2);
    }
}

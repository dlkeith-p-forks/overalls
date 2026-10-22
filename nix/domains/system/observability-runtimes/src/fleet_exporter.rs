mod common;
use std::env;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() -> std::io::Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 2 {
        eprintln!("usage: overalls-fleet-exporter DESCRIPTOR");
        std::process::exit(64);
    }
    let _descriptor = &args[1];
    common::serve("127.0.0.1", 9466, || {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        format!("overalls_fleet_collection_valid 0\noveralls_fleet_collection_failures_total 0\noveralls_fleet_observed_at_seconds {now}\n")
    })
}

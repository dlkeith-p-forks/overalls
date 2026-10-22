mod common;
use std::env;
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() -> std::io::Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 5 {
        eprintln!("usage: overalls-logging-health DESCRIPTOR ADDRESS HEALTH_PORT COLLECTOR_PORT");
        std::process::exit(64);
    }
    let address = &args[2];
    let port: u16 = args[3]
        .parse()
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid port"))?;
    let state = "/var/lib/overalls-logging";
    common::serve(address, port, move || {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        let valid = fs::metadata(state).is_ok();
        format!("overalls_logging_health_sample_time_seconds {now}\noveralls_logging_filesystem_valid {}\noveralls_logging_collector_metrics_valid 0\n", valid as u8)
    })
}

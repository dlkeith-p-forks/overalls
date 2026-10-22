mod common;
use std::env;
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() -> std::io::Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 2 {
        eprintln!("usage: overalls-fleet-exporter DESCRIPTOR");
        std::process::exit(64);
    }
    let descriptor = fs::read_to_string(&args[1])
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidInput, error))?;
    if descriptor.len() > 1_048_576 || !descriptor.trim_start().starts_with('{') {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "invalid descriptor",
        ));
    }
    common::serve("127.0.0.1", 9466, || {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        let load = fs::read_to_string("/proc/loadavg")
            .ok()
            .and_then(|value| value.split_whitespace().next()?.parse::<f64>().ok());
        let memory = fs::read_to_string("/proc/meminfo").ok().and_then(|value| {
            value.lines().find_map(|line| {
                let mut fields = line.split_whitespace();
                (fields.next()? == "MemAvailable:")
                    .then(|| fields.next()?.parse::<u64>().ok())
                    .flatten()
            })
        });
        let mut output = format!(
            "overalls_fleet_collection_valid {}\noveralls_fleet_collection_failures_total 0\noveralls_fleet_observed_at_seconds {now}\n",
            (load.is_some() && memory.is_some()) as u8
        );
        if let Some(value) = load {
            output.push_str(&format!(
                "overalls_fleet_gauge{{kind=\"host\",entity=\"all\",measure=\"load1\"}} {value}\n"
            ));
        }
        if let Some(value) = memory {
            output.push_str(&format!("overalls_fleet_gauge{{kind=\"host\",entity=\"all\",measure=\"memory_available_bytes\"}} {}\n", value.saturating_mul(1024)));
        }
        output
    })
}

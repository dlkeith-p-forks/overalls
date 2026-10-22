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
    let port = descriptor
        .split("\"port\"")
        .nth(1)
        .and_then(|value| value.split(':').nth(1))
        .and_then(|value| {
            value
                .trim()
                .trim_start_matches(':')
                .split(|c: char| !c.is_ascii_digit())
                .next()
        })
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(9466);
    common::serve("127.0.0.1", port, || {
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
        if let Some(status) = updater_status() {
            if let Some(phase) = status.phase {
                output.push_str(&format!(
                    "overalls_fleet_updater_phase{{phase=\"{phase}\"}} 1\n"
                ));
            }
            if let Some(revision) = status.revision {
                output.push_str(&format!(
                    "overalls_fleet_updater_revision_info{{revision=\"{revision}\"}} 1\n"
                ));
            }
        }
        output
    })
}

struct UpdaterStatus {
    phase: Option<String>,
    revision: Option<String>,
}

fn updater_status() -> Option<UpdaterStatus> {
    let text = fs::read_to_string("/var/lib/overalls-auto-update/status.json").ok()?;
    if text.len() > 65_536 {
        return None;
    }
    let phase = text
        .split("\"phase\"")
        .nth(1)
        .and_then(|v| v.split(':').nth(1))
        .and_then(|v| v.split('"').nth(1))
        .filter(|v| {
            matches!(
                *v,
                "fetch"
                    | "build"
                    | "stage"
                    | "preflight"
                    | "migrate"
                    | "activate"
                    | "verify"
                    | "healthy"
                    | "never-run"
            )
        })
        .map(str::to_owned);
    let revision = text
        .split("\"revision\"")
        .nth(1)
        .and_then(|v| v.split(':').nth(1))
        .and_then(|v| v.split('"').nth(1))
        .filter(|v| v.len() == 40 && v.bytes().all(|b| b.is_ascii_hexdigit()))
        .map(str::to_owned);
    (phase.is_some() || revision.is_some()).then_some(UpdaterStatus { phase, revision })
}

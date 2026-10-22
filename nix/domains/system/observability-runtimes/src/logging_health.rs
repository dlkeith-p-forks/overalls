mod common;
use std::env;
use std::fs;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() -> std::io::Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 5 {
        eprintln!("usage: overalls-logging-health DESCRIPTOR ADDRESS HEALTH_PORT COLLECTOR_PORT");
        std::process::exit(64);
    }
    let descriptor = fs::read_to_string(&args[1]).unwrap_or_default();
    let budgets = parse_budgets(&descriptor);
    let address = args[2].clone();
    let port: u16 = args[3]
        .parse()
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid port"))?;
    let collector_port = args[4].parse::<u16>().unwrap_or(0);
    common::serve(&address, port, move || {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        let state = Path::new("/var/lib/overalls-logging");
        let mut out = format!("overalls_logging_health_sample_time_seconds {now}\n");
        let mut valid = fs::metadata(state).is_ok();
        let mut bytes = 0u64;
        let mut oldest = 0u64;
        if let Ok(entries) = fs::read_dir(state.join("chunks")) {
            for entry in entries.flatten().take(100_001) {
                if let Ok(meta) = entry.metadata() {
                    bytes = bytes.saturating_add(meta.len());
                }
                if let Some(stamp) = entry
                    .file_name()
                    .to_str()
                    .and_then(|n| n.split('-').nth(1))
                    .and_then(|n| n.split('.').next())
                    .and_then(|n| n.parse::<u64>().ok())
                {
                    oldest = oldest.max((now as u64).saturating_sub(stamp));
                }
            }
        } else {
            valid = false;
        }
        out.push_str(&format!("overalls_logging_filesystem_valid {}\noveralls_logging_queue_bytes {bytes}\noveralls_logging_oldest_chunk_seconds {oldest}\n", valid as u8));
        let collector = scrape(collector_port);
        out.push_str(&format!(
            "overalls_logging_collector_metrics_valid {}\n",
            collector.is_some() as u8
        ));
        if let Some(body) = collector {
            for line in body.lines().filter(|l| l.starts_with("fluentbit_output_")) {
                out.push_str(line);
                out.push('\n');
            }
        }
        for (name, budget) in &budgets {
            out.push_str(&format!(
                "overalls_logging_output_budget_bytes{{output=\"{name}\"}} {budget}\n"
            ));
            out.push_str(&format!(
                "overalls_logging_output_counters_valid{{output=\"{name}\"}} 0\n"
            ));
        }
        out
    })
}

fn parse_budgets(descriptor: &str) -> Vec<(String, u64)> {
    let section = descriptor
        .split("\"queueBudgets\"")
        .nth(1)
        .and_then(|value| value.split_once('{').map(|(_, rest)| rest))
        .unwrap_or("");
    section
        .split('}')
        .next()
        .unwrap_or("")
        .split(',')
        .filter_map(|entry| {
            let (raw_name, raw_value) = entry.split_once(':')?;
            let name = raw_name.trim().trim_matches('"');
            if name.is_empty()
                || !name
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
            {
                return None;
            }
            let value = raw_value.trim().parse::<u64>().ok()?;
            (value > 0).then(|| (name.to_owned(), value))
        })
        .take(128)
        .collect()
}

fn scrape(port: u16) -> Option<String> {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).ok()?;
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(2)))
        .ok()?;
    stream.write_all(b"GET /api/v1/metrics/prometheus HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n").ok()?;
    let mut body = Vec::new();
    stream.read_to_end(&mut body).ok()?;
    let text = String::from_utf8(body).ok()?;
    Some(
        text.split("\r\n\r\n")
            .nth(1)
            .unwrap_or("")
            .chars()
            .take(1_048_576)
            .collect(),
    )
}

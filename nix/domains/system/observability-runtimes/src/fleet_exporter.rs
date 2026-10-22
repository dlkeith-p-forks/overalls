mod common;
use std::env;
use std::fs;
use std::process::Command;
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
        for interface in descriptor_interfaces(&descriptor) {
            if let Some((rx, tx)) = interface_bytes(&interface) {
                output.push_str(&format!("overalls_fleet_counter{{kind=\"network\",entity=\"{interface}\",measure=\"receive_bytes\"}} {rx}\n"));
                output.push_str(&format!("overalls_fleet_counter{{kind=\"network\",entity=\"{interface}\",measure=\"transmit_bytes\"}} {tx}\n"));
            }
        }
        if let Some(zpool) = descriptor_command(&descriptor, "zpool") {
            for (name, health, size, free) in zpool_metrics(&zpool) {
                output.push_str(&format!("overalls_fleet_gauge{{kind=\"zpool\",entity=\"{name}\",measure=\"size_bytes\"}} {size}\n"));
                output.push_str(&format!("overalls_fleet_gauge{{kind=\"zpool\",entity=\"{name}\",measure=\"free_bytes\"}} {free}\n"));
                output.push_str(&format!("overalls_fleet_info{{kind=\"zpool\",entity=\"{name}\",health=\"{health}\"}} 1\n"));
            }
        }
        if descriptor.contains("\"backups_enabled\":true") {
            if let Some(state) = backup_state() {
                output.push_str(&format!(
                    "overalls_fleet_backup_state{{state=\"{state}\"}} 1\n"
                ));
            }
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
        for unit in descriptor_services(&descriptor) {
            if let Some((active, sub)) = unit_state(&unit) {
                output.push_str(&format!("overalls_fleet_service_state{{unit=\"{}\",active=\"{active}\",sub=\"{sub}\"}} 1\n", unit.replace('"', "")));
            }
            if let Some((memory, cpu)) = cgroup_usage(&unit) {
                output.push_str(&format!("overalls_fleet_gauge{{kind=\"service\",entity=\"{unit}\",measure=\"memory_bytes\"}} {memory}\n"));
                output.push_str(&format!("overalls_fleet_counter{{kind=\"service\",entity=\"{unit}\",measure=\"cpu_usage_usec\"}} {cpu}\n"));
            }
        }
        if let Some(vms) = vm_units() {
            output.push_str(&format!(
                "overalls_fleet_gauge{{kind=\"vm\",entity=\"all\",measure=\"count\"}} {}\n",
                vms.len()
            ));
            for vm in vms {
                output.push_str(&format!(
                    "overalls_fleet_info{{kind=\"vm\",entity=\"{vm}\"}} 1\n"
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

fn descriptor_services(descriptor: &str) -> Vec<String> {
    let section = descriptor
        .split("\"services\"")
        .nth(1)
        .and_then(|v| v.split_once('[').map(|(_, r)| r))
        .unwrap_or("");
    section
        .split(']')
        .next()
        .unwrap_or("")
        .split(',')
        .filter_map(|v| {
            let unit = v.trim().trim_matches('"');
            (unit.len() <= 128
                && unit.ends_with(".service")
                && unit
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_.@:-".contains(&b)))
            .then_some(unit.to_owned())
        })
        .take(128)
        .collect()
}

fn descriptor_interfaces(descriptor: &str) -> Vec<String> {
    let section = descriptor
        .split("\"external_interfaces\"")
        .nth(1)
        .and_then(|v| v.split_once('[').map(|(_, r)| r))
        .unwrap_or("");
    section
        .split(']')
        .next()
        .unwrap_or("")
        .split(',')
        .filter_map(|v| {
            let name = v.trim().trim_matches('"');
            (name.len() <= 15
                && !name.is_empty()
                && name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.' || b == b'-'))
            .then_some(name.to_owned())
        })
        .take(128)
        .collect()
}

fn interface_bytes(interface: &str) -> Option<(u64, u64)> {
    let text = fs::read_to_string("/proc/net/dev").ok()?;
    for line in text.lines().skip(2) {
        let (raw_name, values) = line.split_once(':')?;
        if raw_name.trim() != interface {
            continue;
        }
        let fields: Vec<u64> = values
            .split_whitespace()
            .take(9)
            .filter_map(|v| v.parse().ok())
            .collect();
        if fields.len() >= 9 {
            return Some((fields[0], fields[8]));
        }
    }
    None
}

fn descriptor_command(descriptor: &str, key: &str) -> Option<String> {
    descriptor
        .split(&format!("\"{key}\""))
        .nth(1)?
        .split(':')
        .nth(1)?
        .split('"')
        .nth(1)
        .filter(|v| v.starts_with('/'))
        .map(str::to_owned)
}

fn zpool_metrics(command: &str) -> Vec<(String, String, u64, u64)> {
    let output = Command::new(command)
        .args(["list", "-Hp", "-o", "name,health,size,free"])
        .output()
        .ok();
    let output = match output {
        Some(value) if value.status.success() && value.stdout.len() <= 65_536 => value,
        _ => return Vec::new(),
    };
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .take(128)
        .filter_map(|line| {
            let fields: Vec<&str> = line.split('\t').collect();
            if fields.len() != 4 {
                return None;
            }
            let valid = |v: &str| {
                !v.is_empty()
                    && v.len() <= 128
                    && v.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-' || b == b'.')
            };
            Some((
                fields[0].to_owned(),
                fields[1].to_owned(),
                fields[2].parse().ok()?,
                fields[3].parse().ok()?,
            ))
            .filter(|(name, health, _, _)| valid(name) && valid(health))
        })
        .collect()
}

fn backup_state() -> Option<String> {
    let text = fs::read_to_string("/var/lib/overalls-backups/status.json").ok()?;
    if text.len() > 8192 {
        return None;
    }
    let state = text
        .split("\"state\"")
        .nth(1)?
        .split(':')
        .nth(1)?
        .split('"')
        .nth(1)?;
    matches!(state, "idle" | "running" | "success" | "failed" | "unknown")
        .then_some(state.to_owned())
}

fn unit_state(unit: &str) -> Option<(String, String)> {
    let output = Command::new("systemctl")
        .args([
            "show",
            "--no-pager",
            "--property=ActiveState,SubState",
            unit,
        ])
        .output()
        .ok()?;
    if !output.status.success() || output.stdout.len() > 1024 {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    let mut active = None;
    let mut sub = None;
    for line in text.lines() {
        if let Some(v) = line.strip_prefix("ActiveState=") {
            active = Some(v);
        }
        if let Some(v) = line.strip_prefix("SubState=") {
            sub = Some(v);
        }
    }
    let valid = |v: &str| {
        !v.is_empty()
            && v.len() <= 32
            && v.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    };
    Some((
        active.filter(|v| valid(v))?.to_owned(),
        sub.filter(|v| valid(v))?.to_owned(),
    ))
}

fn cgroup_usage(unit: &str) -> Option<(u64, u64)> {
    let base = format!("/sys/fs/cgroup/system.slice/{unit}");
    let memory = fs::read_to_string(format!("{base}/memory.current"))
        .ok()?
        .trim()
        .parse()
        .ok()?;
    let cpu = fs::read_to_string(format!("{base}/cpu.stat")).ok()?;
    let usage = cpu.lines().find_map(|line| {
        let mut fields = line.split_whitespace();
        (fields.next()? == "usage_usec")
            .then(|| fields.next()?.parse().ok())
            .flatten()
    })?;
    Some((memory, usage))
}

fn vm_units() -> Option<Vec<String>> {
    let output = Command::new("systemctl")
        .args([
            "list-units",
            "--type=service",
            "--all",
            "--no-legend",
            "--no-pager",
        ])
        .output()
        .ok()?;
    if !output.status.success() || output.stdout.len() > 1_048_576 {
        return None;
    }
    Some(
        String::from_utf8(output.stdout)
            .ok()?
            .lines()
            .filter_map(|line| {
                let unit = line.split_whitespace().next()?;
                (unit.starts_with("lilly-vm-")
                    && unit.ends_with(".service")
                    && unit.len() <= 128
                    && unit
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.'))
                .then_some(unit.to_owned())
            })
            .take(2048)
            .collect(),
    )
}

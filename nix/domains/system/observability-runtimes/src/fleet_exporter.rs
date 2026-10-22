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
        if let Some((total, available)) = memory_totals() {
            output.push_str(&format!("overalls_fleet_gauge{{kind=\"host\",entity=\"all\",measure=\"memory_total_bytes\"}} {total}\n"));
            output.push_str(&format!("overalls_fleet_gauge{{kind=\"host\",entity=\"all\",measure=\"memory_used_bytes\"}} {}\n", total.saturating_sub(available)));
        }
        for (device, read_ops, read_sectors, write_ops, write_sectors) in disk_stats() {
            output.push_str(&format!("overalls_fleet_counter{{kind=\"disk\",entity=\"{device}\",measure=\"read_ops\"}} {read_ops}\n"));
            output.push_str(&format!("overalls_fleet_counter{{kind=\"disk\",entity=\"{device}\",measure=\"read_sectors\"}} {read_sectors}\n"));
            output.push_str(&format!("overalls_fleet_counter{{kind=\"disk\",entity=\"{device}\",measure=\"write_ops\"}} {write_ops}\n"));
            output.push_str(&format!("overalls_fleet_counter{{kind=\"disk\",entity=\"{device}\",measure=\"write_sectors\"}} {write_sectors}\n"));
        }
        if let Some(cpu) = fs::read_to_string("/proc/stat")
            .ok()
            .and_then(|v| v.lines().find(|l| l.starts_with("cpu ")).map(str::to_owned))
        {
            let fields: Vec<u64> = cpu
                .split_whitespace()
                .skip(1)
                .take(10)
                .filter_map(|v| v.parse().ok())
                .collect();
            for (name, value) in [
                "user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal",
            ]
            .into_iter()
            .zip(fields)
            {
                output.push_str(&format!("overalls_fleet_counter{{kind=\"cpu\",entity=\"all\",measure=\"{name}_ticks\"}} {value}\n"));
            }
        }
        for (name, value) in vmstat_counters() {
            output.push_str(&format!("overalls_fleet_counter{{kind=\"host\",entity=\"all\",measure=\"{name}\"}} {value}\n"));
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
            append_cgroup_events(&mut output, "service", &unit, "/sys/fs/cgroup/system.slice");
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
                if let Some((memory, cpu)) = cgroup_usage_at("/sys/fs/cgroup/lilly.slice", &vm) {
                    output.push_str(&format!("overalls_fleet_gauge{{kind=\"vm\",entity=\"{vm}\",measure=\"memory_bytes\"}} {memory}\n"));
                    output.push_str(&format!("overalls_fleet_counter{{kind=\"vm\",entity=\"{vm}\",measure=\"cpu_usage_usec\"}} {cpu}\n"));
                }
                append_cgroup_events(&mut output, "vm", &vm, "/sys/fs/cgroup/lilly.slice");
            }
        }
        output
    })
}

fn memory_totals() -> Option<(u64, u64)> {
    let text = fs::read_to_string("/proc/meminfo").ok()?;
    let mut total = None;
    let mut available = None;
    for line in text.lines() {
        let mut fields = line.split_whitespace();
        let Some(name) = fields.next() else { continue };
        let Some(value) = fields.next().and_then(|v| v.parse::<u64>().ok()) else {
            continue;
        };
        let value = value.saturating_mul(1024);
        if name == "MemTotal:" {
            total = Some(value);
        }
        if name == "MemAvailable:" {
            available = Some(value);
        }
    }
    Some((total?, available?))
}

fn disk_stats() -> Vec<(String, u64, u64, u64, u64)> {
    let text = match fs::read_to_string("/proc/diskstats") {
        Ok(value) if value.len() <= 1_048_576 => value,
        _ => return Vec::new(),
    };
    text.lines()
        .take(4096)
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            if fields.len() < 11 {
                return None;
            }
            let name = fields[2];
            if name.is_empty()
                || name.len() > 128
                || !name.bytes().all(|b| {
                    b.is_ascii_alphanumeric() || b == b'_' || b == b'.' || b == b'!' || b == b'-'
                })
            {
                return None;
            }
            Some((
                name.to_owned(),
                fields[3].parse().ok()?,
                fields[5].parse().ok()?,
                fields[7].parse().ok()?,
                fields[9].parse().ok()?,
            ))
        })
        .take(4096)
        .collect()
}

fn vmstat_counters() -> Vec<(String, u64)> {
    let text = match fs::read_to_string("/proc/vmstat") {
        Ok(value) if value.len() <= 262_144 => value,
        _ => return Vec::new(),
    };
    let allowed = [
        "oom_kill",
        "pswpin",
        "pswpout",
        "pgfault",
        "pgmajfault",
        "pgpgin",
        "pgpgout",
    ];
    text.lines()
        .take(4096)
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let name = fields.next()?;
            let value = fields.next()?.parse().ok()?;
            allowed.contains(&name).then_some((name.to_owned(), value))
        })
        .collect()
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
    cgroup_usage_at("/sys/fs/cgroup/system.slice", unit)
}

fn cgroup_usage_at(parent: &str, unit: &str) -> Option<(u64, u64)> {
    let base = format!("{parent}/{unit}");
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

fn append_cgroup_events(output: &mut String, kind: &str, entity: &str, parent: &str) {
    let base = format!("{parent}/{entity}");
    if let Ok(text) = fs::read_to_string(format!("{base}/memory.events")) {
        for line in text.lines().take(16) {
            let mut fields = line.split_whitespace();
            let Some(name) = fields.next() else { continue };
            let Some(value) = fields.next().and_then(|v| v.parse::<u64>().ok()) else {
                continue;
            };
            if matches!(
                name,
                "low" | "high" | "max" | "oom" | "oom_kill" | "oom_group_kill"
            ) {
                output.push_str(&format!("overalls_fleet_counter{{kind=\"{kind}\",entity=\"{entity}\",measure=\"memory_{name}\"}} {value}\n"));
            }
        }
    }
    if let Ok(text) = fs::read_to_string(format!("{base}/cpu.max")) {
        let fields: Vec<&str> = text.split_whitespace().collect();
        if fields.len() == 2 && fields[0] != "max" {
            if let (Ok(quota), Ok(period)) = (fields[0].parse::<f64>(), fields[1].parse::<f64>()) {
                if quota.is_finite() && period > 0.0 {
                    output.push_str(&format!("overalls_fleet_gauge{{kind=\"{kind}\",entity=\"{entity}\",measure=\"cpu_limit_cores\"}} {}\n", quota / period));
                }
            }
        }
    }
    if let Ok(text) = fs::read_to_string(format!("{base}/memory.stat")) {
        for line in text.lines().take(64) {
            let mut fields = line.split_whitespace();
            let Some(name @ ("anon" | "file" | "kernel" | "slab")) = fields.next() else {
                continue;
            };
            let Some(value) = fields.next().and_then(|v| v.parse::<u64>().ok()) else {
                continue;
            };
            output.push_str(&format!("overalls_fleet_gauge{{kind=\"{kind}\",entity=\"{entity}\",measure=\"memory_{name}_bytes\"}} {value}\n"));
        }
    }
    for pressure in ["cpu", "memory", "io"] {
        if let Ok(text) = fs::read_to_string(format!("{base}/{pressure}.pressure")) {
            for line in text.lines().take(4) {
                let mut fields = line.split_whitespace();
                let Some(class) = fields.next() else { continue };
                if !matches!(class, "some" | "full") {
                    continue;
                }
                for field in fields {
                    let Some((name, value)) = field.split_once('=') else {
                        continue;
                    };
                    if matches!(name, "avg10" | "avg60" | "avg300" | "total") {
                        if let Ok(value) = value.parse::<f64>() {
                            if value.is_finite() {
                                output.push_str(&format!("overalls_fleet_gauge{{kind=\"{kind}\",entity=\"{entity}\",measure=\"pressure_{pressure}_{class}_{name}\"}} {value}\n"));
                            }
                        }
                    }
                }
            }
        }
    }
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

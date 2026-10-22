//! Host namespace exporter for source-owned application SLO snapshots.

use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry_proto::tonic::common::v1::{any_value::Value, AnyValue, KeyValue};
use opentelemetry_proto::tonic::metrics::v1::{
    metric::Data, number_data_point::Value as NumberValue, AggregationTemporality, Gauge,
    Histogram, HistogramDataPoint, Metric, NumberDataPoint, Sum,
};
use opentelemetry_proto::tonic::resource::v1::Resource;
use prost::Message;
use serde::{Deserialize, Serialize};
use std::fs::{File, Metadata, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const SNAPSHOT_LIMIT: u64 = 4096;
const BOUNDS_US: [u64; 7] = [
    10_000, 50_000, 100_000, 500_000, 1_000_000, 5_000_000, 10_000_000,
];
const MAX_COUNTER: u64 = i64::MAX as u64;
const LIFECYCLE_BOUNDS_US: [u64; 7] = [
    1_000_000,
    5_000_000,
    10_000_000,
    30_000_000,
    120_000_000,
    600_000_000,
    3_000_000_000,
];

fn lifecycle_service(service: &str) -> bool {
    matches!(
        service,
        "marshall_ready"
            | "lilly_physical"
            | "porsche_physical"
            | "porsche_clone"
            | "porsche_relocate"
            | "porsche_retry"
            | "porsche_cancel"
    )
}

const UNDERCLASS_BOUNDS_US: [u64; 15] = [
    10_000,
    50_000,
    100_000,
    500_000,
    1_000_000,
    5_000_000,
    10_000_000,
    30_000_000,
    60_000_000,
    120_000_000,
    300_000_000,
    900_000_000,
    3_600_000_000,
    21_600_000_000,
    86_400_000_000,
];

/// @cc [owner:ghuntley,label:reliability;security] service-histogram-bounds
/// Each fixed source identity owns exactly one histogram bound set. A snapshot
/// whose bounds differ from its configured service MUST be refused; no source
/// may export a second duration histogram.
fn service_bounds(service: &str) -> &'static [u64] {
    if lifecycle_service(service) {
        &LIFECYCLE_BOUNDS_US
    } else if matches!(service, "vscode_browser_nixos" | "vscode_browser_ubuntu") {
        &crate::durable_slo::BROWSER_BOUNDS_US
    } else if service == "underclass_proxy" {
        &UNDERCLASS_BOUNDS_US
    } else {
        &BOUNDS_US
    }
}

/// One cumulative duration histogram whose bounds belong to the snapshot's
/// configured service; `bucket_counts` has one overflow bucket beyond them.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct DurationSample {
    count: u64,
    sum_us: u64,
    explicit_bounds_us: Vec<u64>,
    bucket_counts: Vec<u64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Snapshot {
    version: u8,
    service: String,
    sampled_at_unix_nano: u64,
    started_at_unix_nano: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    coverage_started_at_unix_nano: Option<u64>,
    incarnation: String,
    invocation_id: String,
    requests: u64,
    successes: u64,
    failures: u64,
    duration: DurationSample,
}

fn hex_identity(value: &str) -> bool {
    value.len() == 32
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

fn coverage_start(snapshot: &Snapshot) -> u64 {
    snapshot
        .coverage_started_at_unix_nano
        .unwrap_or(snapshot.started_at_unix_nano)
}

// @cc [owner:ghuntley,label:security;reliability] application-slo-snapshot-validation
// Reject stale, malformed, unowned or nonmonotonic source snapshots before OTLP
// export. No snapshot field may become an arbitrary metric name or label.
fn valid(
    snapshot: &Snapshot,
    expected_service: &str,
    previous: Option<&Snapshot>,
    now: u64,
) -> bool {
    if snapshot.version != 1
        || snapshot.service != expected_service
        || !hex_identity(&snapshot.incarnation)
        || !hex_identity(&snapshot.invocation_id)
        || snapshot.started_at_unix_nano == 0
        || snapshot.sampled_at_unix_nano < snapshot.started_at_unix_nano
        || coverage_start(snapshot) < snapshot.started_at_unix_nano
        || coverage_start(snapshot) > snapshot.sampled_at_unix_nano
        || snapshot.sampled_at_unix_nano > now.saturating_add(2_000_000_000)
        || now.saturating_sub(snapshot.sampled_at_unix_nano) > 15_000_000_000
        || snapshot.duration.explicit_bounds_us.as_slice() != service_bounds(expected_service)
        || snapshot.duration.bucket_counts.len() != snapshot.duration.explicit_bounds_us.len() + 1
        || [
            snapshot.requests,
            snapshot.successes,
            snapshot.failures,
            snapshot.duration.count,
            snapshot.duration.sum_us,
        ]
        .iter()
        .any(|value| *value > MAX_COUNTER)
        || snapshot.requests != snapshot.successes.saturating_add(snapshot.failures)
        || snapshot.duration.count > snapshot.requests
        || snapshot
            .duration
            .bucket_counts
            .iter()
            .try_fold(0u64, |sum, value| sum.checked_add(*value))
            != Some(snapshot.duration.count)
        || snapshot
            .duration
            .bucket_counts
            .iter()
            .any(|value| *value > MAX_COUNTER)
    {
        return false;
    }
    if let Some(old) = previous {
        if old.incarnation == snapshot.incarnation {
            if old.started_at_unix_nano != snapshot.started_at_unix_nano
                || old.invocation_id != snapshot.invocation_id
                || coverage_start(old) > coverage_start(snapshot)
                || old.sampled_at_unix_nano >= snapshot.sampled_at_unix_nano
                || old.requests > snapshot.requests
                || old.successes > snapshot.successes
                || old.failures > snapshot.failures
                || old.duration.count > snapshot.duration.count
                || old.duration.sum_us > snapshot.duration.sum_us
                || old.duration.bucket_counts.len() != snapshot.duration.bucket_counts.len()
                || old
                    .duration
                    .bucket_counts
                    .iter()
                    .zip(snapshot.duration.bucket_counts.iter())
                    .any(|(before, after)| before > after)
            {
                return false;
            }
        } else if snapshot.started_at_unix_nano <= old.started_at_unix_nano {
            return false;
        }
    }
    true
}

fn read_snapshot(path: &Path, uid: u32) -> Result<Snapshot, &'static str> {
    read_snapshot_with_group(path, uid, None)
}

// @cc [owner:ghuntley,label:security] isolated-source-file-custody
// Accept only a non-root-owned source directory with group traverse but no
// group write, and a non-root source-group file with mode 0640. The exporter
// must be unable to replace the file through directory write permission.
fn read_group_snapshot(path: &Path, gid: u32) -> Result<Snapshot, &'static str> {
    let parent: &Path = path.parent().ok_or("parent")?;
    let directory: Metadata = std::fs::symlink_metadata(parent).map_err(|_| "directory")?;
    if !directory.is_dir()
        || directory.uid() == 0
        || directory.gid() != gid
        || directory.mode() & 0o777 != 0o750
    {
        return Err("directory_custody");
    }
    read_snapshot_with_group(path, 0, Some(gid))
}

fn read_snapshot_with_group(
    path: &Path,
    uid: u32,
    source_gid: Option<u32>,
) -> Result<Snapshot, &'static str> {
    let file: File = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| "open")?;
    let meta: Metadata = file.metadata().map_err(|_| "metadata")?;
    let custody = match source_gid {
        Some(gid) => meta.uid() != 0 && meta.gid() == gid && meta.mode() & 0o777 == 0o640,
        None => meta.uid() == uid && meta.mode() & 0o777 == 0o600,
    };
    if !meta.is_file() || !custody || meta.len() > SNAPSHOT_LIMIT {
        return Err("ownership");
    }
    let mut bytes = Vec::new();
    file.take(SNAPSHOT_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "read")?;
    if bytes.len() as u64 > SNAPSHOT_LIMIT {
        return Err("size");
    }
    serde_json::from_slice(&bytes).map_err(|_| "schema")
}

fn attribute(key: &str, value: &str) -> KeyValue {
    KeyValue {
        key: key.to_owned(),
        value: Some(AnyValue {
            value: Some(Value::StringValue(value.to_owned())),
        }),
    }
}

fn sum(name: &str, value: u64, snapshot: &Snapshot) -> Metric {
    Metric {
        name: name.to_owned(),
        data: Some(Data::Sum(Sum {
            data_points: vec![NumberDataPoint {
                start_time_unix_nano: snapshot.started_at_unix_nano,
                time_unix_nano: snapshot.sampled_at_unix_nano,
                value: Some(NumberValue::AsInt(value as i64)),
                ..Default::default()
            }],
            aggregation_temporality: AggregationTemporality::Cumulative as i32,
            is_monotonic: true,
        })),
        ..Default::default()
    }
}

fn encode(snapshot: &Snapshot) -> Vec<u8> {
    encode_with_instance(snapshot, None)
}

/// @cc [owner:ghuntley,label:reliability] source-start-visibility
/// Every trusted application snapshot MUST export its source start time as
/// a fixed gauge so recording rules can reject windows after counter resets.
fn encode_with_instance(snapshot: &Snapshot, instance: Option<&str>) -> Vec<u8> {
    let mut request = ExportMetricsServiceRequest::default();
    let mut attributes = vec![attribute("service.name", &snapshot.service)];
    if let Some(instance) = instance {
        attributes.push(attribute("service.instance.id", instance));
    }
    let mut resource = opentelemetry_proto::tonic::metrics::v1::ResourceMetrics {
        resource: Some(Resource {
            attributes,
            ..Default::default()
        }),
        ..Default::default()
    };
    let mut scope = opentelemetry_proto::tonic::metrics::v1::ScopeMetrics::default();
    scope.metrics.push(sum(
        &format!("overalls.outer.{}.requests", snapshot.service),
        snapshot.requests,
        snapshot,
    ));
    scope.metrics.push(sum(
        &format!("overalls.outer.{}.successes", snapshot.service),
        snapshot.successes,
        snapshot,
    ));
    scope.metrics.push(sum(
        &format!("overalls.outer.{}.failures", snapshot.service),
        snapshot.failures,
        snapshot,
    ));
    scope.metrics.push(Metric {
        name: format!("overalls.outer.{}.source_start_time", snapshot.service),
        // Keep the Prometheus family name stable; the value is Unix seconds.
        unit: String::new(),
        data: Some(Data::Gauge(Gauge {
            data_points: vec![NumberDataPoint {
                time_unix_nano: snapshot.sampled_at_unix_nano,
                value: Some(NumberValue::AsDouble(
                    snapshot.started_at_unix_nano as f64 / 1_000_000_000.0,
                )),
                ..Default::default()
            }],
        })),
        ..Default::default()
    });
    scope.metrics.push(Metric {
        name: format!("overalls.outer.{}.duration", snapshot.service),
        unit: "s".to_owned(),
        data: Some(Data::Histogram(Histogram {
            data_points: vec![HistogramDataPoint {
                start_time_unix_nano: snapshot.started_at_unix_nano,
                time_unix_nano: snapshot.sampled_at_unix_nano,
                count: snapshot.duration.count,
                sum: Some(snapshot.duration.sum_us as f64 / 1_000_000.0),
                bucket_counts: snapshot.duration.bucket_counts.clone(),
                explicit_bounds: snapshot
                    .duration
                    .explicit_bounds_us
                    .iter()
                    .map(|bound| *bound as f64 / 1_000_000.0)
                    .collect(),
                ..Default::default()
            }],
            aggregation_temporality: AggregationTemporality::Cumulative as i32,
        })),
        ..Default::default()
    });
    scope.metrics.push(Metric {
        name: format!(
            "overalls.outer.{}.source_coverage_start_time",
            snapshot.service
        ),
        unit: String::new(),
        data: Some(Data::Gauge(Gauge {
            data_points: vec![NumberDataPoint {
                time_unix_nano: snapshot.sampled_at_unix_nano,
                value: Some(NumberValue::AsDouble(
                    coverage_start(snapshot) as f64 / 1_000_000_000.0,
                )),
                ..Default::default()
            }],
        })),
        ..Default::default()
    });
    // @cc [owner:ghuntley,label:reliability] source-time-survives-collector-cache
    // A fixed numeric source sampling clock MUST accompany every snapshot so
    // fresh Prometheus scrapes of retained collector values cannot imply a
    // live source. The clock MUST come from the validated source snapshot.
    scope.metrics.push(Metric {
        name: format!("overalls.outer.{}.source_sample_time", snapshot.service),
        unit: String::new(),
        data: Some(Data::Gauge(Gauge {
            data_points: vec![NumberDataPoint {
                time_unix_nano: snapshot.sampled_at_unix_nano,
                value: Some(NumberValue::AsDouble(
                    snapshot.sampled_at_unix_nano as f64 / 1_000_000_000.0,
                )),
                ..Default::default()
            }],
        })),
        ..Default::default()
    });
    resource.scope_metrics.push(scope);
    request.resource_metrics.push(resource);
    request.encode_to_vec()
}

fn send(body: &[u8], socket: &str) -> Result<(), &'static str> {
    let mut stream = UnixStream::connect(socket).map_err(|_| "connect")?;
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .map_err(|_| "timeout")?;
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .map_err(|_| "timeout")?;
    write!(stream, "POST /v1/metrics HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-protobuf\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len())
        .map_err(|_| "write")?;
    stream.write_all(body).map_err(|_| "write")?;
    let mut response = [0u8; 32];
    let count = stream.read(&mut response).map_err(|_| "response")?;
    if count < 12 || !response[..count].starts_with(b"HTTP/1.1 200") {
        return Err("rejected");
    }
    Ok(())
}

fn now_ns() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .min(u128::from(u64::MAX)) as u64
}

/// Export only fixed, locally configured service identities.
/// `source` is Ziggy's private snapshot file or a group-custody snapshot file.
pub fn run(service: &str, source: &Path, collector_socket: &str) -> Result<(), &'static str> {
    run_with_instance(service, source, collector_socket, None)
}

// @cc [owner:ghuntley,label:security;reliability] fixed-application-instance-identity
// A Nix-configured replica identity MAY distinguish trusted source counters.
// It MUST use a bounded static alphabet and MUST NOT come from the snapshot.
pub fn run_with_instance(
    service: &str,
    source: &Path,
    collector_socket: &str,
    instance: Option<&str>,
) -> Result<(), &'static str> {
    run_with_custody(
        service,
        source,
        collector_socket,
        instance,
        SourceCustody::Direct,
    )
}

/// Configured custody of the trusted application source.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SourceCustody {
    /// The producer itself writes the snapshot: Ziggy's exporter-owned private
    /// file, or the Underclass and Marshall lifecycle group-custody files.
    Direct,
    /// A durable request recorder writes a group-custody snapshot.
    RecorderGroup,
}

/// @cc [owner:ghuntley,label:security] recorder-source-explicit-read-only-custody
/// RecorderGroup MUST accept only the closed recorder request sources and an
/// exact primary-group-owned, non-writable snapshot. Selecting this mode MUST
/// NOT fall back to private files.

/// @cc [owner:ghuntley,label:security] direct-source-closed-set
/// Direct custody MUST accept only sources without a request recorder: Ziggy
/// (exporter-owned private file), Underclass proxy and the lifecycle sources
/// (group-custody files). Recorder-backed request sources MUST be refused.
pub fn run_with_custody(
    service: &str,
    source: &Path,
    collector_socket: &str,
    instance: Option<&str>,
    custody: SourceCustody,
) -> Result<(), &'static str> {
    let allowed = match custody {
        SourceCustody::RecorderGroup => matches!(
            service,
            "brady"
                | "galileo"
                | "enrico"
                | "porsche"
                | "audi_private"
                | "audi_dns"
                | "audi_ssh"
                | "marshall_web"
                | "marshall_live"
                | "vscode_browser_nixos"
                | "vscode_browser_ubuntu"
        ),
        SourceCustody::Direct => {
            service == "ziggy" || service == "underclass_proxy" || lifecycle_service(service)
        }
    };
    if !allowed {
        return Err("service");
    }
    if let Some(instance) = instance {
        if instance.is_empty()
            || instance.len() > 64
            || !instance
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
        {
            return Err("instance");
        }
    }
    let uid = unsafe { libc::geteuid() };
    let mut previous: Option<Snapshot> = None;
    loop {
        let candidate = if custody == SourceCustody::Direct && service == "ziggy" {
            read_snapshot(source, uid)
        } else {
            read_group_snapshot(source, unsafe { libc::getegid() })
        };
        if let Ok(snapshot) = candidate {
            if valid(&snapshot, service, previous.as_ref(), now_ns()) {
                let body = match instance {
                    Some(instance) => encode_with_instance(&snapshot, Some(instance)),
                    None => encode(&snapshot),
                };
                if send(&body, collector_socket).is_ok() {
                    previous = Some(snapshot);
                }
            }
        }
        std::thread::sleep(Duration::from_secs(5));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::os::unix::fs::{symlink, PermissionsExt};

    fn sample(requests: u64, successes: u64) -> Snapshot {
        Snapshot {
            version: 1,
            coverage_started_at_unix_nano: None,
            service: "brady".into(),
            sampled_at_unix_nano: 3_000_000_000,
            started_at_unix_nano: 1_000_000_000,
            incarnation: "a".repeat(32),
            invocation_id: "b".repeat(32),
            requests,
            successes,
            failures: requests - successes,
            duration: DurationSample {
                count: requests,
                sum_us: requests * 100,
                explicit_bounds_us: BOUNDS_US.to_vec(),
                bucket_counts: vec![requests, 0, 0, 0, 0, 0, 0, 0],
            },
        }
    }

    proptest! {
        #[test]
        fn browser_recorder_histogram_survives_validated_otlp_export(duration in 0u64..80_000_000) {
            use crate::durable_slo::{Outcome, Producer, Source, State};
            for source in [Source::VscodeBrowserNixos, Source::VscodeBrowserUbuntu] {
                let mut state = State::new(source, 1, "a".repeat(32)).unwrap();
                let producer = Producer { pid: 1, start_ticks: 1,
                    boot_id: "00000000-0000-0000-0000-000000000001".to_owned() };
                let id = state.admit(producer.clone(), 2, 100_000_000_000).unwrap();
                state.finish(id, &producer, 3, Outcome::Success, duration).unwrap();
                let bytes = crate::request_recorder::snapshot_bytes(&state, 4).unwrap();
                let mut snapshot: Snapshot = serde_json::from_slice(&bytes).unwrap();
                prop_assert!(valid(&snapshot, source.name(), None, 4));
                let decoded = ExportMetricsServiceRequest::decode(encode(&snapshot).as_slice()).unwrap();
                let histogram = decoded.resource_metrics[0].scope_metrics[0].metrics.iter()
                    .find_map(|metric| match &metric.data {
                        Some(Data::Histogram(histogram)) => Some(&histogram.data_points[0]),
                        _ => None,
                    }).unwrap();
                prop_assert_eq!(&histogram.explicit_bounds,
                    &vec![0.1, 0.5, 1.0, 5.0, 10.0, 30.0, 60.0]);
                prop_assert_eq!(histogram.count, 1);
                prop_assert_eq!(histogram.bucket_counts.iter().sum::<u64>(), 1);
                snapshot.duration.explicit_bounds_us = BOUNDS_US.to_vec();
                prop_assert!(!valid(&snapshot, source.name(), None, 4));
            }
        }

        /// @cc [owner:ghuntley,label:verification] underclass-single-histogram-export
        /// Generated Underclass histories MUST validate and export exactly one
        /// 15-bound duration histogram; conservation breaks, foreign bounds,
        /// bucket-shape changes and bound reuse by another service are refused.
        #[test]
        fn underclass_exports_one_fifteen_bound_histogram(durations in prop::collection::vec(0u64..100_000_000_000, 1..40)) {
            let n = durations.len() as u64;
            let mut snapshot = sample(n, n);
            snapshot.service = "underclass_proxy".to_owned();
            let mut buckets = vec![0u64; 16];
            for duration in &durations {
                let index = UNDERCLASS_BOUNDS_US.iter().position(|b| duration <= b).unwrap_or(15);
                buckets[index] += 1;
            }
            snapshot.duration = DurationSample {
                count: n, sum_us: durations.iter().sum(),
                explicit_bounds_us: UNDERCLASS_BOUNDS_US.to_vec(), bucket_counts: buckets,
            };
            prop_assert!(valid(&snapshot, "underclass_proxy", None, snapshot.sampled_at_unix_nano));
            let encoded = ExportMetricsServiceRequest::decode(encode(&snapshot).as_slice()).unwrap();
            let metrics = &encoded.resource_metrics[0].scope_metrics[0].metrics;
            prop_assert_eq!(metrics.len(), 7);
            let histograms: Vec<&Metric> = metrics.iter()
                .filter(|m| matches!(m.data, Some(Data::Histogram(_)))).collect();
            prop_assert_eq!(histograms.len(), 1);
            prop_assert_eq!(histograms[0].name.as_str(), "overalls.outer.underclass_proxy.duration");
            let Some(Data::Histogram(histogram)) = &histograms[0].data else { panic!("histogram missing"); };
            prop_assert_eq!(&histogram.data_points[0].explicit_bounds,
                &UNDERCLASS_BOUNDS_US.map(|bound| bound as f64 / 1_000_000.0).to_vec());
            prop_assert_eq!(histogram.data_points[0].bucket_counts.len(), 16);
            let mut broken = snapshot.clone();
            broken.duration.bucket_counts[0] += 1;
            prop_assert!(!valid(&broken, "underclass_proxy", None, broken.sampled_at_unix_nano));
            let mut short = snapshot.clone();
            short.duration.bucket_counts.pop();
            prop_assert!(!valid(&short, "underclass_proxy", None, short.sampled_at_unix_nano));
            let mut legacy = sample(n, n);
            legacy.service = "underclass_proxy".to_owned();
            prop_assert!(!valid(&legacy, "underclass_proxy", None, legacy.sampled_at_unix_nano));
            snapshot.service = "brady".to_owned();
            prop_assert!(!valid(&snapshot, "brady", None, snapshot.sampled_at_unix_nano));
        }
    }

    proptest! {
        #[test]
        fn coverage_clocks_never_reset_counters_or_allow_quality_regression(gap in 1_000_000_000_u64..3_000_000_000) {
            let original = sample(10, 7);
            let mut newer = original.clone();
            newer.sampled_at_unix_nano += 1;
            newer.coverage_started_at_unix_nano = Some(gap);
            prop_assert!(valid(&newer, "brady", Some(&original), newer.sampled_at_unix_nano));
            let decoded = ExportMetricsServiceRequest::decode(encode(&newer).as_slice()).unwrap();
            let metric = decoded.resource_metrics[0].scope_metrics[0].metrics.iter()
                .find(|metric| metric.name == "overalls.outer.brady.source_coverage_start_time").unwrap();
            let Some(Data::Gauge(gauge)) = &metric.data else { panic!("coverage clock missing"); };
            prop_assert_eq!(gauge.data_points[0].value, Some(NumberValue::AsDouble(gap as f64 / 1_000_000_000.0)));
            let mut regression = newer.clone();
            regression.sampled_at_unix_nano += 1;
            regression.coverage_started_at_unix_nano = Some(gap - 1);
            prop_assert!(!valid(&regression, "brady", Some(&newer), regression.sampled_at_unix_nano));
            regression.coverage_started_at_unix_nano = Some(regression.sampled_at_unix_nano + 1);
            prop_assert!(!valid(&regression, "brady", None, regression.sampled_at_unix_nano));
        }
        #[test]
        fn generated_lifecycle_histograms_keep_fixed_service_bounds(requests in 0u64..100_000, successes in 0u64..100_000) {
            for service in ["marshall_ready", "lilly_physical", "porsche_physical",
                "porsche_clone", "porsche_relocate", "porsche_retry", "porsche_cancel"] {
                let mut snapshot = sample(requests, successes.min(requests));
                snapshot.service = service.to_owned();
                snapshot.duration.explicit_bounds_us = LIFECYCLE_BOUNDS_US.to_vec();
                prop_assert!(valid(&snapshot, service, None, snapshot.sampled_at_unix_nano));
                let encoded = encode(&snapshot);
                let decoded = ExportMetricsServiceRequest::decode(encoded.as_slice()).unwrap();
                let metrics = &decoded.resource_metrics[0].scope_metrics[0].metrics;
                let histogram = metrics.iter().find_map(|metric| match &metric.data {
                    Some(Data::Histogram(histogram)) => Some(histogram),
                    _ => None,
                }).unwrap();
                prop_assert_eq!(&histogram.data_points[0].explicit_bounds,
                    &LIFECYCLE_BOUNDS_US.map(|bound| bound as f64 / 1_000_000.0).to_vec());
                snapshot.duration.explicit_bounds_us = BOUNDS_US.to_vec();
                prop_assert!(!valid(&snapshot, service, None, snapshot.sampled_at_unix_nano));
            }
        }
        #[test]
        fn generated_outcome_arithmetic_and_monotonicity(requests in 0u64..100_000, successes in 0u64..100_000) {
            let successes = successes.min(requests);
            let first = sample(requests, successes);
            prop_assert!(valid(&first, "brady", None, 3_000_000_000));
            let mut next = sample(requests + 1, successes + 1);
            next.sampled_at_unix_nano += 1;
            prop_assert!(valid(&next, "brady", Some(&first), 3_000_000_001));
            next.failures += 1;
            prop_assert!(!valid(&next, "brady", Some(&first), 3_000_000_001));
            let decoded = ExportMetricsServiceRequest::decode(encode(&first).as_slice()).unwrap();
            prop_assert_eq!(decoded.resource_metrics[0].scope_metrics[0].metrics.len(), 7);
            let start = &decoded.resource_metrics[0].scope_metrics[0].metrics[3];
            prop_assert_eq!(start.name.as_str(), "overalls.outer.brady.source_start_time");
            let sampled = &decoded.resource_metrics[0].scope_metrics[0].metrics[6];
            prop_assert_eq!(sampled.name.as_str(), "overalls.outer.brady.source_sample_time");
            let Some(Data::Gauge(clock)) = &sampled.data else { panic!("source clock missing"); };
            prop_assert_eq!(clock.data_points[0].value, Some(NumberValue::AsDouble(first.sampled_at_unix_nano as f64 / 1_000_000_000.0)));
            let Some(Data::Gauge(gauge)) = &start.data else { return Err(proptest::test_runner::TestCaseError::fail("missing source start gauge")); };
            prop_assert_eq!(gauge.data_points[0].value, Some(NumberValue::AsDouble(1.0)));
            let mut galileo = first.clone();
            galileo.service = "galileo".to_owned();
            prop_assert!(valid(&galileo, "galileo", None, 3_000_000_000));
            prop_assert!(!valid(&galileo, "brady", None, 3_000_000_000));
            let galileo_otlp = ExportMetricsServiceRequest::decode(encode(&galileo).as_slice()).unwrap();
            prop_assert_eq!(galileo_otlp.resource_metrics[0].scope_metrics[0].metrics[0].name.as_str(), "overalls.outer.galileo.requests");
            let mut enrico = first.clone();
            enrico.service = "enrico".to_owned();
            prop_assert!(valid(&enrico, "enrico", None, 3_000_000_000));
            prop_assert!(!valid(&enrico, "brady", None, 3_000_000_000));
            let enrico_otlp = ExportMetricsServiceRequest::decode(encode(&enrico).as_slice()).unwrap();
            prop_assert_eq!(enrico_otlp.resource_metrics[0].scope_metrics[0].metrics[0].name.as_str(), "overalls.outer.enrico.requests");
            let mut porsche = first.clone();
            porsche.service = "porsche".to_owned();
            prop_assert!(valid(&porsche, "porsche", None, 3_000_000_000));
            prop_assert!(!valid(&porsche, "brady", None, 3_000_000_000));
            let porsche_otlp = ExportMetricsServiceRequest::decode(encode(&porsche).as_slice()).unwrap();
            prop_assert_eq!(porsche_otlp.resource_metrics[0].scope_metrics[0].metrics[0].name.as_str(), "overalls.outer.porsche.requests");
            let mut ziggy = first.clone();
            ziggy.service = "ziggy".to_owned();
            prop_assert!(valid(&ziggy, "ziggy", None, 3_000_000_000));
            prop_assert!(!valid(&ziggy, "brady", None, 3_000_000_000));
            let ziggy_otlp = ExportMetricsServiceRequest::decode(encode(&ziggy).as_slice()).unwrap();
            prop_assert_eq!(ziggy_otlp.resource_metrics[0].scope_metrics[0].metrics[0].name.as_str(), "overalls.outer.ziggy.requests");
            let mut audi = first.clone();
            audi.service = "audi_private".to_owned();
            prop_assert!(valid(&audi, "audi_private", None, 3_000_000_000));
            prop_assert!(!valid(&audi, "ziggy", None, 3_000_000_000));
            let audi_otlp = ExportMetricsServiceRequest::decode(encode(&audi).as_slice()).unwrap();
            prop_assert_eq!(audi_otlp.resource_metrics[0].scope_metrics[0].metrics[0].name.as_str(), "overalls.outer.audi_private.requests");
            let mut dns = first.clone();
            dns.service = "audi_dns".to_owned();
            prop_assert!(valid(&dns, "audi_dns", None, 3_000_000_000));
            prop_assert!(!valid(&dns, "audi_private", None, 3_000_000_000));
            let dns_otlp = ExportMetricsServiceRequest::decode(encode(&dns).as_slice()).unwrap();
            prop_assert_eq!(dns_otlp.resource_metrics[0].scope_metrics[0].metrics[0].name.as_str(), "overalls.outer.audi_dns.requests");
            let mut marshall = first.clone();
            marshall.service = "marshall_web".to_owned();
            prop_assert!(valid(&marshall, "marshall_web", None, 3_000_000_000));
            let marshall_otlp = ExportMetricsServiceRequest::decode(encode_with_instance(&marshall, Some("overalls_a")).as_slice()).unwrap();
            prop_assert_eq!(marshall_otlp.resource_metrics[0].scope_metrics[0].metrics[0].name.as_str(), "overalls.outer.marshall_web.requests");
            prop_assert_eq!(marshall_otlp.resource_metrics[0].resource.as_ref().unwrap().attributes[1].key.as_str(), "service.instance.id");
            let mut ssh = first.clone();
            ssh.service = "audi_ssh".to_owned();
            prop_assert!(valid(&ssh, "audi_ssh", None, 3_000_000_000));
            let ssh_otlp = ExportMetricsServiceRequest::decode(encode(&ssh).as_slice()).unwrap();
            prop_assert_eq!(ssh_otlp.resource_metrics[0].scope_metrics[0].metrics[0].name.as_str(), "overalls.outer.audi_ssh.requests");
        }
    }

    #[test]
    fn private_file_custody_rejects_public_mode_and_symlink() {
        let root =
            std::env::temp_dir().join(format!("overalls-slo-{}-{}", std::process::id(), now_ns()));
        std::fs::create_dir(&root).unwrap();
        let path = root.join("slo.json");
        std::fs::write(&path, serde_json::to_vec(&sample(2, 1)).unwrap()).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let uid = unsafe { libc::geteuid() };
        assert!(read_snapshot(&path, uid).is_ok());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read_snapshot(&path, uid).is_err());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(read_snapshot(&path, uid.saturating_add(1)).is_err());
        let alias = root.join("alias.json");
        symlink(&path, &alias).unwrap();
        assert!(read_snapshot(&alias, uid).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn marshall_group_file_requires_exact_read_only_custody() {
        let root = std::env::temp_dir().join(format!(
            "overalls-marshall-slo-{}-{}",
            std::process::id(),
            now_ns()
        ));
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o750)).unwrap();
        let path = root.join("slo.json");
        std::fs::write(&path, serde_json::to_vec(&sample(2, 1)).unwrap()).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
        let gid = unsafe { libc::getegid() };
        assert!(read_group_snapshot(&path, gid).is_ok());
        assert!(read_group_snapshot(&path, gid.saturating_add(1)).is_err());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o660)).unwrap();
        assert!(read_group_snapshot(&path, gid).is_err());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o770)).unwrap();
        assert!(read_group_snapshot(&path, gid).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn recorder_custody_refuses_sources_without_request_recorders() {
        for service in ["ziggy", "underclass_proxy", "lilly_lifecycle", "unknown"] {
            assert_eq!(
                run_with_custody(
                    service,
                    Path::new("/nonexistent"),
                    "/nonexistent",
                    None,
                    SourceCustody::RecorderGroup,
                ),
                Err("service")
            );
        }
    }

    #[test]
    fn direct_custody_refuses_recorder_backed_sources() {
        for service in [
            "brady",
            "galileo",
            "enrico",
            "porsche",
            "audi_private",
            "audi_dns",
            "audi_ssh",
            "marshall_web",
            "marshall_live",
            "vscode_browser_nixos",
            "vscode_browser_ubuntu",
            "unknown",
        ] {
            assert_eq!(
                run_with_custody(
                    service,
                    Path::new("/nonexistent"),
                    "/nonexistent",
                    None,
                    SourceCustody::Direct,
                ),
                Err("service")
            );
        }
    }

    #[test]
    fn instance_identity_rejects_unbounded_or_untrusted_label_syntax() {
        let source = Path::new("/nonexistent");
        assert_eq!(
            run_with_instance("marshall_ready", source, "/nonexistent", Some("")),
            Err("instance")
        );
        assert_eq!(
            run_with_instance("marshall_ready", source, "/nonexistent", Some("host/name")),
            Err("instance")
        );
        assert_eq!(
            run_with_instance(
                "marshall_ready",
                source,
                "/nonexistent",
                Some(&"x".repeat(65))
            ),
            Err("instance")
        );
    }
}

//! Sanitization boundary for telemetry from user controlled VMs.

pub mod browser_probe;
pub mod durable_slo;
pub mod request_recorder;
pub mod slo;
pub mod underclass_probe;

use base64::Engine;
use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry_proto::tonic::collector::trace::v1::ExportTraceServiceRequest;
use opentelemetry_proto::tonic::common::v1::{any_value::Value, AnyValue, KeyValue};
use opentelemetry_proto::tonic::resource::v1::Resource;
use prost::Message;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::{Duration, Instant};

const MAX_METRICS: usize = 128;
const MAX_POINTS: usize = 1024;
const MAX_SPANS: usize = 256;
const VM_BYTES_PER_MINUTE: usize = 1_048_576;
const HOST_BYTES_PER_MINUTE: usize = 2_097_152;
const VM_REQUESTS_PER_MINUTE: usize = 60;
const HOST_REQUESTS_PER_MINUTE: usize = 120;
const MAX_ACTIVE_VMS: usize = 4096;

#[derive(Debug)]
struct Window {
    since: Instant,
    bytes: usize,
    requests: usize,
}

impl Window {
    fn new(now: Instant) -> Self {
        Self {
            since: now,
            bytes: 0,
            requests: 0,
        }
    }

    fn refresh(&mut self, now: Instant) {
        if now.duration_since(self.since) >= Duration::from_secs(60) {
            *self = Self::new(now);
        }
    }

    fn fits(&self, bytes: usize, byte_limit: usize, request_limit: usize) -> bool {
        self.requests < request_limit && bytes <= byte_limit.saturating_sub(self.bytes)
    }

    fn record(&mut self, bytes: usize) {
        self.bytes += bytes;
        self.requests += 1;
    }
}

#[derive(Debug)]
pub struct IntakeLimit {
    host: Window,
    vms: HashMap<String, Window>,
}

impl IntakeLimit {
    pub fn new(now: Instant) -> Self {
        Self {
            host: Window::new(now),
            vms: HashMap::new(),
        }
    }

    // @cc [owner:ghuntley,label:capacity] guest-telemetry-bounded
    // Each VM and host MUST stay within fixed rolling-window byte/request
    // limits, and the number of tracked VM windows MUST remain bounded.
    pub fn admit(&mut self, binding: &Binding, bytes: usize, now: Instant) -> bool {
        self.host.refresh(now);
        if !self
            .host
            .fits(bytes, HOST_BYTES_PER_MINUTE, HOST_REQUESTS_PER_MINUTE)
        {
            return false;
        }
        if !self.vms.contains_key(&binding.vm_id) && self.vms.len() >= MAX_ACTIVE_VMS {
            self.vms
                .retain(|_, window| now.duration_since(window.since) < Duration::from_secs(60));
            if self.vms.len() >= MAX_ACTIVE_VMS {
                return false;
            }
        }
        let vm = self
            .vms
            .entry(binding.vm_id.clone())
            .or_insert_with(|| Window::new(now));
        vm.refresh(now);
        if !vm.fits(bytes, VM_BYTES_PER_MINUTE, VM_REQUESTS_PER_MINUTE) {
            return false;
        }
        self.host.record(bytes);
        vm.record(bytes);
        true
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Binding {
    pub host_id: String,
    pub vm_id: String,
    pub placement_id: String,
    pub execution_epoch: u64,
}

fn canonical_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                *byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(byte)
            }
        })
}

pub fn parse_binding(header: &str) -> Result<Binding, &'static str> {
    if header.len() > 512 || header.contains('=') {
        return Err("binding_size");
    }
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(header)
        .map_err(|_| "binding_encoding")?;
    let binding: Binding = serde_json::from_slice(&bytes).map_err(|_| "binding_json")?;
    if !canonical_uuid(&binding.host_id)
        || !canonical_uuid(&binding.vm_id)
        || !canonical_uuid(&binding.placement_id)
        || binding.execution_epoch == 0
    {
        return Err("binding_identity");
    }
    Ok(binding)
}

fn safe_name(name: &str, max_len: usize, first_alpha: bool) -> bool {
    let bytes = name.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= max_len
        && (!first_alpha || bytes[0].is_ascii_alphabetic())
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(*byte, b'_' | b'-' | b'.' | b' '))
}

fn allowed_metric(name: &str) -> bool {
    matches!(
        name,
        "overalls.guest.requests"
            | "overalls.guest.errors"
            | "overalls.guest.duration"
            | "overalls.guest.active"
            | "overalls.guest.tool_calls"
            | "overalls.guest.tool_errors"
            | "overalls.guest.tokens"
            | "overalls.guest.ready"
    )
}

fn service_name(resource: &Resource) -> &'static str {
    const SERVICES: &[&str] = &[
        "marshall", "lilly", "audi", "porsche", "ziggy", "galileo", "enrico", "brady", "lyra",
    ];
    for attribute in &resource.attributes {
        if attribute.key == "service.name" {
            if let Some(AnyValue {
                value: Some(Value::StringValue(value)),
            }) = &attribute.value
            {
                if let Some(service) = SERVICES.iter().find(|service| **service == value) {
                    return service;
                }
            }
        }
    }
    "unknown"
}

fn attribute(key: &str, value: String) -> KeyValue {
    KeyValue {
        key: key.to_owned(),
        value: Some(AnyValue {
            value: Some(Value::StringValue(value)),
        }),
    }
}

fn replace_resource(resource: &mut Resource, binding: &Binding, service: &str) {
    resource.attributes = vec![
        attribute("service.name", format!("guest-{service}")),
        attribute("overalls.telemetry.origin", "guest".to_owned()),
        attribute("overalls.outer.host_id", binding.host_id.clone()),
        attribute("overalls.outer.vm_id", binding.vm_id.clone()),
        attribute("overalls.outer.placement_id", binding.placement_id.clone()),
        attribute(
            "overalls.outer.execution_epoch",
            binding.execution_epoch.to_string(),
        ),
    ];
    resource.dropped_attributes_count = 0;
}

// @cc [owner:ghuntley,label:security] guest-telemetry-untrusted
// Only the guest metric namespace and closed resource labels may leave this process.
pub fn sanitize_metrics(body: &[u8], binding: &Binding) -> Result<Vec<u8>, &'static str> {
    let mut request = ExportMetricsServiceRequest::decode(body).map_err(|_| "protobuf")?;
    let mut metric_count = 0usize;
    let mut point_count = 0usize;
    for resource in &mut request.resource_metrics {
        let original = resource.resource.get_or_insert_with(Resource::default);
        let service = service_name(original);
        replace_resource(original, binding, service);
        resource.schema_url.clear();
        for scope in &mut resource.scope_metrics {
            if let Some(instrumentation) = &mut scope.scope {
                instrumentation.attributes.clear();
                instrumentation.name = "overalls-guest".to_owned();
                instrumentation.version.clear();
                instrumentation.dropped_attributes_count = 0;
            }
            scope.schema_url.clear();
            for metric in &mut scope.metrics {
                metric_count += 1;
                if metric_count > MAX_METRICS || !allowed_metric(&metric.name) {
                    return Err("metric_name_or_count");
                }
                metric.description.clear();
                metric.unit.clear();
                use opentelemetry_proto::tonic::metrics::v1::metric::Data;
                match metric.data.as_mut().ok_or("metric_kind")? {
                    Data::Gauge(data) => {
                        point_count += data.data_points.len();
                        for point in &mut data.data_points {
                            point.attributes.clear();
                            point.exemplars.clear();
                        }
                    }
                    Data::Sum(data) => {
                        point_count += data.data_points.len();
                        for point in &mut data.data_points {
                            point.attributes.clear();
                            point.exemplars.clear();
                        }
                    }
                    Data::Histogram(data) => {
                        point_count += data.data_points.len();
                        for point in &mut data.data_points {
                            if point.explicit_bounds.len() > 32 {
                                return Err("histogram_bounds");
                            }
                            point.attributes.clear();
                            point.exemplars.clear();
                        }
                    }
                    _ => return Err("metric_kind"),
                }
                if point_count > MAX_POINTS {
                    return Err("point_count");
                }
            }
        }
    }
    if metric_count == 0 {
        return Err("empty_metrics");
    }
    Ok(request.encode_to_vec())
}

pub fn sanitize_traces(body: &[u8], binding: &Binding) -> Result<Vec<u8>, &'static str> {
    let mut request = ExportTraceServiceRequest::decode(body).map_err(|_| "protobuf")?;
    let mut span_count = 0usize;
    for resource in &mut request.resource_spans {
        let original = resource.resource.get_or_insert_with(Resource::default);
        let service = service_name(original);
        replace_resource(original, binding, service);
        resource.schema_url.clear();
        for scope in &mut resource.scope_spans {
            if let Some(instrumentation) = &mut scope.scope {
                instrumentation.attributes.clear();
                instrumentation.name = "overalls-guest".to_owned();
                instrumentation.version.clear();
                instrumentation.dropped_attributes_count = 0;
            }
            scope.schema_url.clear();
            for span in &mut scope.spans {
                span_count += 1;
                if span_count > MAX_SPANS || !safe_name(&span.name, 80, true) {
                    return Err("span_name_or_count");
                }
                span.attributes.clear();
                span.events.clear();
                span.links.clear();
                span.trace_state.clear();
                span.dropped_attributes_count = 0;
                span.dropped_events_count = 0;
                span.dropped_links_count = 0;
                if let Some(status) = &mut span.status {
                    status.message.clear();
                }
            }
        }
    }
    if span_count == 0 {
        return Err("empty_traces");
    }
    Ok(request.encode_to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;
    use opentelemetry_proto::tonic::metrics::v1::{metric::Data, Gauge, Metric, NumberDataPoint};
    use opentelemetry_proto::tonic::trace::v1::{span, Span};
    use proptest::prelude::*;

    fn binding() -> Binding {
        Binding {
            host_id: "12345678-1234-1234-1234-123456789abc".to_owned(),
            vm_id: "22345678-1234-1234-1234-123456789abc".to_owned(),
            placement_id: "32345678-1234-1234-1234-123456789abc".to_owned(),
            execution_epoch: 7,
        }
    }

    fn request(name: &str, secret: &str) -> ExportMetricsServiceRequest {
        let mut request = ExportMetricsServiceRequest::default();
        let mut resource = opentelemetry_proto::tonic::metrics::v1::ResourceMetrics {
            resource: Some(Resource {
                attributes: vec![attribute("overalls.outer.vm_id", secret.to_owned())],
                ..Default::default()
            }),
            ..Default::default()
        };
        let mut scope = opentelemetry_proto::tonic::metrics::v1::ScopeMetrics::default();
        scope.metrics.push(Metric {
            name: name.to_owned(),
            unit: secret.to_owned(),
            data: Some(Data::Gauge(Gauge {
                data_points: vec![NumberDataPoint {
                    attributes: vec![attribute("secret", secret.to_owned())],
                    ..Default::default()
                }],
            })),
            ..Default::default()
        });
        resource.scope_metrics.push(scope);
        request.resource_metrics.push(resource);
        request
    }

    proptest! {
        #[test]
        fn host_budget_bounds_many_guests(
            uploads in proptest::collection::vec((0u16..4096, 1usize..65536), 0..300)
        ) {
            let now = Instant::now();
            let mut limiter = IntakeLimit::new(now);
            let mut accepted_bytes = 0usize;
            let mut accepted_requests = 0usize;
            for (guest, size) in uploads {
                let mut identity = binding();
                identity.vm_id = format!("{guest:08x}-1234-1234-1234-123456789abc");
                if limiter.admit(&identity, size, now) {
                    accepted_bytes += size;
                    accepted_requests += 1;
                }
            }
            prop_assert!(accepted_bytes <= HOST_BYTES_PER_MINUTE);
            prop_assert!(accepted_requests <= HOST_REQUESTS_PER_MINUTE);
        }

        #[test]
        fn guest_rate_budget_bounds_arbitrary_uploads(sizes in proptest::collection::vec(0usize..1_048_577, 0..200)) {
            let now = Instant::now();
            let mut limiter = IntakeLimit::new(now);
            let mut accepted_bytes = 0usize;
            let mut accepted_requests = 0usize;
            for size in sizes {
                if limiter.admit(&binding(), size, now) {
                    accepted_bytes += size;
                    accepted_requests += 1;
                }
            }
            prop_assert!(accepted_bytes <= VM_BYTES_PER_MINUTE);
            prop_assert!(accepted_requests <= VM_REQUESTS_PER_MINUTE);
        }

        #[test]
        fn valid_binding_round_trips(epoch in 1u64..u64::MAX) {
            let mut expected = binding();
            expected.execution_epoch = epoch;
            let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
                serde_json::to_vec(&expected).expect("serialize fixture")
            );
            prop_assert_eq!(parse_binding(&encoded), Ok(expected));
        }

        #[test]
        fn guest_cannot_claim_outer_metric(name in "[a-zA-Z0-9_.]{0,30}") {
            let name = format!("overalls.outer.{name}");
            let body = request(&name, "secret").encode_to_vec();
            prop_assert!(sanitize_metrics(&body, &binding()).is_err());
        }

        #[test]
        fn guest_cannot_expand_metric_vocabulary(name in "[a-z]{1,20}") {
            let name = format!("overalls.guest.unreviewed_{name}");
            let body = request(&name, "secret").encode_to_vec();
            prop_assert!(sanitize_metrics(&body, &binding()).is_err());
        }

        #[test]
        fn guest_resource_and_dimensions_are_replaced(secret in ".{0,100}") {
            let body = request("overalls.guest.requests", &secret).encode_to_vec();
            let clean = sanitize_metrics(&body, &binding()).expect("valid guest metric");
            let parsed = ExportMetricsServiceRequest::decode(clean.as_slice()).expect("clean protobuf");
            let resource = &parsed.resource_metrics[0];
            let attributes = &resource.resource.as_ref().expect("resource").attributes;
            prop_assert_eq!(attributes[0].key.as_str(), "service.name");
            prop_assert_eq!(attributes[1].key.as_str(), "overalls.telemetry.origin");
            prop_assert_eq!(attributes[3].value.as_ref().and_then(|value| value.value.as_ref()),
                Some(&Value::StringValue(binding().vm_id)));
            let metric = &resource.scope_metrics[0].metrics[0];
            prop_assert!(metric.unit.is_empty());
            if let Some(Data::Gauge(gauge)) = &metric.data {
                prop_assert!(gauge.data_points[0].attributes.is_empty());
            } else {
                prop_assert!(false);
            }
        }

        #[test]
        fn traces_drop_guest_events_and_attributes(secret in ".{0,100}") {
            let mut request = ExportTraceServiceRequest::default();
            let mut resource = opentelemetry_proto::tonic::trace::v1::ResourceSpans::default();
            let mut scope = opentelemetry_proto::tonic::trace::v1::ScopeSpans::default();
            scope.spans.push(Span {
                name: "guest.work".to_owned(),
                attributes: vec![attribute("secret", secret.clone())],
                events: vec![span::Event { name: secret.clone(), ..Default::default() }],
                links: vec![span::Link { trace_state: secret.clone(), ..Default::default() }],
                ..Default::default()
            });
            resource.scope_spans.push(scope);
            request.resource_spans.push(resource);
            let clean = sanitize_traces(&request.encode_to_vec(), &binding()).expect("valid span");
            let parsed = ExportTraceServiceRequest::decode(clean.as_slice()).expect("clean protobuf");
            let span = &parsed.resource_spans[0].scope_spans[0].spans[0];
            prop_assert!(span.attributes.is_empty() && span.events.is_empty() && span.links.is_empty());
        }
    }

    #[test]
    fn metric_count_is_bounded() {
        let mut request = request("overalls.guest.requests", "secret");
        let metric = request.resource_metrics[0].scope_metrics[0].metrics[0].clone();
        request.resource_metrics[0].scope_metrics[0]
            .metrics
            .resize(129, metric);
        assert!(sanitize_metrics(&request.encode_to_vec(), &binding()).is_err());
    }

    #[test]
    fn budgets_reopen_after_window_expires() {
        let now = Instant::now();
        let mut limiter = IntakeLimit::new(now);
        assert!(limiter.admit(&binding(), VM_BYTES_PER_MINUTE, now));
        assert!(!limiter.admit(&binding(), 1, now));
        assert!(limiter.admit(
            &binding(),
            VM_BYTES_PER_MINUTE,
            now + Duration::from_secs(60)
        ));
    }
}

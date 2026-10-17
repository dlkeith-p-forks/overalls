//! Regenerate the machine-test OTLP fixture: cargo run --example fixture > fixture.hex.
use opentelemetry_proto::tonic::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry_proto::tonic::metrics::v1::{metric::Data, Gauge, Metric, NumberDataPoint};
use prost::Message;

fn main() {
    let mut request = ExportMetricsServiceRequest::default();
    let mut resource = opentelemetry_proto::tonic::metrics::v1::ResourceMetrics::default();
    let mut scope = opentelemetry_proto::tonic::metrics::v1::ScopeMetrics::default();
    scope.metrics.push(Metric {
        name: "overalls.guest.requests".to_owned(),
        data: Some(Data::Gauge(Gauge {
            data_points: vec![NumberDataPoint {
                value: Some(
                    opentelemetry_proto::tonic::metrics::v1::number_data_point::Value::AsInt(1),
                ),
                ..Default::default()
            }],
        })),
        ..Default::default()
    });
    resource.scope_metrics.push(scope);
    request.resource_metrics.push(resource);
    for byte in request.encode_to_vec() {
        print!("{byte:02x}");
    }
    println!();
}

//! Fixed-service host exporter for source-owned application SLO snapshots.

use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (custody, args) = match args.as_slice() {
        [flag, rest @ ..] if flag == "--recorder-group-source" => (
            overalls_otel_guest_receiver::slo::SourceCustody::RecorderGroup,
            rest,
        ),
        args => (
            overalls_otel_guest_receiver::slo::SourceCustody::Direct,
            args,
        ),
    };
    let (service, source, collector, instance) = match args {
        [service, source, collector] => {
            (service.as_str(), source.as_str(), collector.as_str(), None)
        }
        [service, source, collector, instance] => (
            service.as_str(),
            source.as_str(),
            collector.as_str(),
            Some(instance.as_str()),
        ),
        _ => std::process::exit(2),
    };
    if overalls_otel_guest_receiver::slo::run_with_custody(
        service,
        Path::new(source),
        collector,
        instance,
        custody,
    )
    .is_err()
    {
        std::process::exit(2);
    }
}

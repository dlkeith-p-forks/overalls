use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [monitor, collector] = args.as_slice() else {
        std::process::exit(2);
    };
    overalls_otel_guest_receiver::underclass_probe::run(Path::new(monitor), Path::new(collector));
}

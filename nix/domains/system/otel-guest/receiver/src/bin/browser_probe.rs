use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [driver, fixture, chromium] = args.as_slice() else {
        std::process::exit(2);
    };
    let Some(socket) = std::env::var_os("OVERALLS_REQUEST_ACCOUNTING_SOCKET") else {
        std::process::exit(2);
    };
    overalls_otel_guest_receiver::browser_probe::run(
        Path::new(&socket),
        Path::new(driver),
        Path::new(fixture),
        Path::new(chromium),
    );
}

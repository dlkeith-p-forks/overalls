#![deny(unsafe_code)]

use lilly_launch_guard::{parse_cli, run, EXIT_USAGE};
use std::process::ExitCode;

fn main() -> ExitCode {
    // No output on any path: success means this process became jailer. The
    // caller (the VM service definition) emits catalogued operational events.
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    match parse_cli(&arguments) {
        None => ExitCode::from(EXIT_USAGE),
        Some(request) => ExitCode::from(run(&request)),
    }
}

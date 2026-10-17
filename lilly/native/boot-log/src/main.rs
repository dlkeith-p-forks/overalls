#![deny(unsafe_code)]

use lilly_boot_log::{parse_cli, run, EXIT_USAGE};
use std::process::ExitCode;

fn main() -> ExitCode {
    // The child's bytes belong to the private log file, never to this process's
    // own output. The caller's events go through the reviewed Lilly catalog.
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    match parse_cli(&arguments) {
        None => ExitCode::from(EXIT_USAGE),
        Some(request) => ExitCode::from(run(&request)),
    }
}

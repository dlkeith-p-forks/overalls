#![deny(unsafe_code)]

use lilly_ingress_bridge::{parse_cli, run, EXIT_USAGE};
use std::process::ExitCode;

fn main() -> ExitCode {
    // Nothing is written to stdout or stderr: guest bytes stay in kernel
    // pipes, and hostd sees only the closed exit status.
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    match parse_cli(&arguments) {
        None => ExitCode::from(EXIT_USAGE),
        Some(request) => ExitCode::from(run(&request)),
    }
}

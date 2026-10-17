#![deny(unsafe_code)]

use lilly_transfer_stream::{parse_cli, run, EXIT_USAGE};
use std::process::ExitCode;

fn main() -> ExitCode {
    // Nothing is written to stdout or stderr: disk bytes and side diagnostics
    // stay in kernel pipes, and hostd returns only the closed exit status.
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    match parse_cli(&arguments) {
        None => ExitCode::from(EXIT_USAGE),
        Some(request) => ExitCode::from(run(&request)),
    }
}

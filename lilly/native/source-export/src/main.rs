#![deny(unsafe_code)]

use lilly_source_export::{parse_cli, run, EXIT_USAGE};
use std::process::ExitCode;

fn main() -> ExitCode {
    // Disk bytes belong to the sender's inherited stdout only; this process
    // never reports diagnostics. The Erlang caller records reviewed events.
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    match parse_cli(&arguments) {
        None => ExitCode::from(EXIT_USAGE),
        Some(request) => ExitCode::from(run(&request)),
    }
}

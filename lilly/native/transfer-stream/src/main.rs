#![deny(unsafe_code)]

use lilly_transfer_stream::{parse_cli, run, with_env, EXIT_USAGE};
use std::process::ExitCode;

fn main() -> ExitCode {
    // stdout carries only the nonce echo and optional progress frames; disk
    // bytes never touch this process's output. Lilly owns all logging.
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    match parse_cli(&arguments) {
        None => ExitCode::from(EXIT_USAGE),
        Some(mut request) => {
            if !with_env(&mut request) {
                return ExitCode::from(EXIT_USAGE);
            }
            ExitCode::from(run(&request))
        }
    }
}

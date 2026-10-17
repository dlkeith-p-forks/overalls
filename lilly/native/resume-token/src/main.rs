#![deny(unsafe_code)]

use lilly_resume_token::{parse_cli, run, EXIT_USAGE};
use std::process::ExitCode;

fn main() -> ExitCode {
    // The verdict word is the entire output; tokens, keys and library messages
    // never print on any path from this process.
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    match parse_cli(&arguments) {
        None => ExitCode::from(EXIT_USAGE),
        Some(request) => ExitCode::from(run(&request)),
    }
}

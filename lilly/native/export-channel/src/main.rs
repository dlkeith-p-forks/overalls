#![deny(unsafe_code)]

use lilly_export_channel::{bridge, parse_bridge, parse_serve, serve, EXIT_USAGE};
use std::os::fd::AsFd;
use std::process::ExitCode;

fn main() -> ExitCode {
    // argv[0] shape: bridge <socket> <key> | serve <account> <worker...>.
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    match arguments.first().and_then(|head| head.to_str()) {
        Some("bridge") => match parse_bridge(
            &arguments[1..],
            std::env::var_os("SSH_ORIGINAL_COMMAND").as_deref(),
        ) {
            None => ExitCode::from(EXIT_USAGE),
            Some(request) => ExitCode::from(bridge(&request)),
        },
        Some("serve") => match parse_serve(&arguments[1..]) {
            None => ExitCode::from(EXIT_USAGE),
            Some(request) => ExitCode::from(serve(&request, std::io::stdin().as_fd())),
        },
        _ => ExitCode::from(EXIT_USAGE),
    }
}

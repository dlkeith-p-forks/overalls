#![deny(unsafe_code)]

use lilly_vm_watch::{parse_cli, watch, Outcome};
use std::io::Write as _;
use std::process::ExitCode;

fn main() -> ExitCode {
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    let mut out = std::io::stdout().lock();
    let outcome = match parse_cli(&arguments) {
        Some(target) => watch(&target, &mut out),
        None => Outcome::Error,
    };
    let line = match outcome {
        Outcome::Exited => "exited",
        Outcome::Error => "error",
        Outcome::Detached => return ExitCode::SUCCESS,
    };
    let written = writeln!(out, "{line}").and_then(|()| out.flush()).is_ok();
    if written && outcome == Outcome::Exited {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

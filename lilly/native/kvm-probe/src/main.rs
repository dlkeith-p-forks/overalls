#![deny(unsafe_code)]

use lilly_kvm_probe::probe;
use std::process::ExitCode;

fn main() -> ExitCode {
    // No arguments are accepted or consulted; stdout stays empty on every path.
    // The caller emits catalogued operational events for this boundary.
    match probe() {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => ExitCode::from(1),
    }
}

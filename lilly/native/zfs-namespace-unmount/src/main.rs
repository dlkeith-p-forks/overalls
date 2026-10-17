#![deny(unsafe_code)]

use lilly_zfs_namespace_unmount::{sweep, SweepResult};
use std::io::Write as _;
use std::process::ExitCode;

fn main() -> ExitCode {
    // The framed outcome line is the whole diagnostic surface. The caller
    // (Lilly) emits catalogued events; paths and mount contents never log here.
    let arguments: Vec<_> = std::env::args_os().collect();
    if arguments.len() != 3 {
        return ExitCode::FAILURE;
    }
    let Some(dataset) = arguments[1].to_str() else {
        return ExitCode::FAILURE;
    };
    let Some(path) = arguments[2].to_str() else {
        return ExitCode::FAILURE;
    };
    if !lilly_zfs_namespace_unmount::valid_dataset(dataset)
        || !lilly_zfs_namespace_unmount::valid_path(path)
    {
        return ExitCode::FAILURE;
    }
    match sweep(dataset, path) {
        Err(_) => ExitCode::FAILURE,
        Ok(SweepResult::Cleaned(count)) => {
            let _ = writeln!(std::io::stdout(), "cleaned {count}");
            ExitCode::SUCCESS
        }
        Ok(SweepResult::Busy) => {
            let _ = writeln!(std::io::stdout(), "busy");
            ExitCode::SUCCESS
        }
        Ok(SweepResult::Unconfirmed) => {
            let _ = writeln!(std::io::stdout(), "unconfirmed");
            ExitCode::SUCCESS
        }
    }
}

//! Native guest broker entry point. Both platforms share closed admission.

#[cfg(target_os = "linux")]
mod linux_main;
#[cfg(windows)]
mod windows_main;

fn main() -> std::process::ExitCode {
    #[cfg(target_os = "linux")]
    return linux_main::main();
    #[cfg(windows)]
    return windows_main::main();
    #[cfg(not(any(target_os = "linux", windows)))]
    std::process::ExitCode::FAILURE
}

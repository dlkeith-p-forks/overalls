//! The Linux guest's agent-executor host: the self-updated binary's digest,
//! guest telemetry, the closed CLI log and the supervisor's runtime markers.
use crate::log::{self, Event};
use lyra::agent::{FetchEvent, Host};
use std::io;
use std::time::Duration;

const STOP_FILE: &str = "/run/overalls-agent/stop";
const READY_FILE: &str = "/run/overalls-agent/ready";

/// The executor running under `overalls agent-supervisor` on Linux guests.
pub(crate) struct Guest;

impl Host for Guest {
    fn digest(&self) -> io::Result<String> {
        crate::update::current_digest()
    }

    fn tool_result(&self, command_id: &str, completed: bool, duration: Duration) {
        crate::telemetry::tool_result(command_id, completed, duration);
    }

    fn fetch_event(&self, event: FetchEvent) {
        let event = match event {
            FetchEvent::Started => Event::FetchStarted,
            FetchEvent::Completed => Event::FetchCompleted,
            FetchEvent::Failed => Event::FetchFailed,
        };
        let _ = log::emit(event, None);
    }

    fn stop_requested(&self) -> bool {
        std::path::Path::new(STOP_FILE).exists()
    }

    fn ready(&self, digest: &str) {
        let _ = std::fs::write(READY_FILE, digest.as_bytes());
    }
}

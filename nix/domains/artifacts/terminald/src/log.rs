//! Closed structured JSON logging; terminal bytes cannot enter this API.
use std::io::Write;
use std::sync::Mutex;

static SINK: Mutex<()> = Mutex::new(());

#[derive(Clone, Copy)]
pub struct Context<'a> {
  pub placement_id: &'a str,
  pub execution_epoch: &'a str,
}

#[derive(Clone, Copy)]
pub enum Event<'a> {
  MissingBootIdentity,
  ListenFailed { errno: i32 },
  Started { port: u32 },
  PeerRejected { cid: u32 },
  FrameRejected,
  AuthRejected,
  SessionCreated { context: Context<'a>, session_id: u64, cols: u16, rows: u16 },
  SessionKilled { context: Context<'a>, session_id: u64 },
  SessionResized { context: Context<'a>, session_id: u64, cols: u16, rows: u16 },
  SessionAttached { context: Context<'a>, session_id: u64, writable: bool, replay_bytes: usize, replay_from: u64 },
  SessionDetachedLast { context: Context<'a>, session_id: u64 },
  PumpSpawnFailed { context: Context<'a>, session_id: u64 },
  SessionExited { context: Context<'a>, session_id: u64 },
  SessionIdleExpired { context: Context<'a>, session_id: u64 },
}

/// @cc [owner:ghuntley,label:security;observability] terminald-closed-log-events
/// Only this enum may define emitted names, levels, messages and field keys.
/// Variants MUST accept identifiers, bounded numbers or closed values only;
/// terminal bytes, user names, titles, commands and payloads have no log type.
pub fn event(event: Event<'_>) {
  let line = encode(event, now_ms());
  let guard = SINK.lock();
  write_line(&line);
  drop(guard);
}

/// Linux guests log to stdout, which the service manager collects.
#[cfg(unix)]
fn write_line(line: &str) {
  let mut out = std::io::stdout().lock();
  let _ = out.write_all(line.as_bytes());
  let _ = out.flush();
}

/// Windows guests run the daemon as a SYSTEM task without a console, so lines
/// append to the agents' log directory next to the other agents' logs.
#[cfg(windows)]
fn write_line(line: &str) {
  let _ = std::fs::create_dir_all(r"C:\overalls\logs");
  if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(r"C:\overalls\logs\terminald.log") {
    let _ = file.write_all(line.as_bytes());
  }
}

fn encode(event: Event<'_>, timestamp_ms: u64) -> String {
  let mut fields = String::new();
  let (name, level, message) = match event {
    Event::MissingBootIdentity => ("terminald.missing_boot_identity", "error", "boot identity unavailable"),
    Event::ListenFailed { errno } => {
      number(&mut fields, "errno", errno);
      ("terminald.listen_failed", "error", "vsock listener failed")
    }
    Event::Started { port } => {
      number(&mut fields, "port", port);
      ("terminald.started", "info", "terminal daemon started")
    }
    Event::PeerRejected { cid } => {
      number(&mut fields, "cid", cid);
      ("terminald.peer_rejected", "warning", "non-host peer rejected")
    }
    Event::FrameRejected => ("terminald.frame_rejected", "warning", "invalid frame rejected"),
    Event::AuthRejected => ("terminald.auth_rejected", "warning", "authentication rejected"),
    Event::SessionCreated { context, session_id, cols, rows } => {
      context_fields(&mut fields, context);
      number(&mut fields, "session_id", session_id);
      number(&mut fields, "cols", cols);
      number(&mut fields, "rows", rows);
      ("terminald.session_created", "info", "terminal session created")
    }
    Event::SessionKilled { context, session_id } => session(&mut fields, context, session_id, "terminald.session_killed", "terminal session killed"),
    Event::SessionResized { context, session_id, cols, rows } => {
      context_fields(&mut fields, context);
      number(&mut fields, "session_id", session_id);
      number(&mut fields, "cols", cols);
      number(&mut fields, "rows", rows);
      ("terminald.session_resized", "info", "terminal session resized")
    }
    Event::SessionAttached { context, session_id, writable, replay_bytes, replay_from } => {
      context_fields(&mut fields, context);
      number(&mut fields, "session_id", session_id);
      string(&mut fields, "mode", if writable { "rw" } else { "ro" });
      number(&mut fields, "replay_bytes", replay_bytes);
      number(&mut fields, "replay_from", replay_from);
      ("terminald.session_attached", "info", "terminal viewer attached")
    }
    Event::SessionDetachedLast { context, session_id } => session(&mut fields, context, session_id, "terminald.session_detached_last", "last terminal viewer detached"),
    Event::PumpSpawnFailed { context, session_id } => session(&mut fields, context, session_id, "terminald.pump_spawn_failed", "terminal pump failed to start"),
    Event::SessionExited { context, session_id } => session(&mut fields, context, session_id, "terminald.session_exited", "terminal session exited"),
    Event::SessionIdleExpired { context, session_id } => session(&mut fields, context, session_id, "terminald.session_idle_expired", "idle terminal session expired"),
  };
  format!("{{\"timestamp_ms\":{timestamp_ms},\"level\":\"{level}\",\"event\":\"{name}\",\"message\":\"{message}\"{fields}}}\n")
}

fn session<'a>(fields: &mut String, context: Context<'a>, id: u64, name: &'a str, message: &'a str) -> (&'a str, &'static str, &'a str) {
  context_fields(fields, context);
  number(fields, "session_id", id);
  (name, "info", message)
}

fn context_fields(fields: &mut String, context: Context<'_>) {
  string(fields, "placement_id", context.placement_id);
  string(fields, "execution_epoch", context.execution_epoch);
}

fn number(fields: &mut String, key: &str, value: impl std::fmt::Display) { fields.push_str(&format!(",\"{key}\":{value}")); }
fn string(fields: &mut String, key: &str, value: &str) { fields.push_str(&format!(",\"{key}\":\"{}\"", escape(value))); }
fn escape(value: &str) -> String {
  let mut escaped = String::with_capacity(value.len());
  for value in value.chars() {
    match value {
      '"' => escaped.push_str("\\\""),
      '\\' => escaped.push_str("\\\\"),
      control if (control as u32) < 0x20 => escaped.push_str(&format!("\\u{:04x}", control as u32)),
      other => escaped.push(other),
    }
  }
  escaped
}

#[cfg(windows)]
pub fn now_ms() -> u64 {
  std::time::SystemTime::now()
    .duration_since(std::time::UNIX_EPOCH)
    .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
    .unwrap_or(0)
}

#[cfg(unix)]
pub fn now_ms() -> u64 {
  let mut time = libc::timespec { tv_sec: 0, tv_nsec: 0 };
  unsafe { libc::clock_gettime(libc::CLOCK_REALTIME, &mut time) };
  (time.tv_sec as u64) * 1000 + (time.tv_nsec / 1_000_000) as u64
}

#[cfg(test)]
mod tests {
  use super::{encode, Context, Event};

  #[test]
  fn encoding_has_fixed_schema_and_numeric_values() {
    let line = encode(Event::SessionCreated {
      context: Context { placement_id: "placement", execution_epoch: "epoch" },
      session_id: 7,
      cols: 80,
      rows: 24,
    }, 42);
    assert_eq!(line, "{\"timestamp_ms\":42,\"level\":\"info\",\"event\":\"terminald.session_created\",\"message\":\"terminal session created\",\"placement_id\":\"placement\",\"execution_epoch\":\"epoch\",\"session_id\":7,\"cols\":80,\"rows\":24}\n");
  }
}

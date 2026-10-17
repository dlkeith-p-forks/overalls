//! Boot-bound native filesystem flush daemon (vsock port 1026).

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
mod daemon {
    use lyra::platform::native::Listener;
    use serde::{Deserialize, Serialize};
    use std::io::{self, BufRead, BufReader, Write};

    const PORT: u32 = 1026;
    const MAX_LINE: usize = 1024;

    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Request {
        version: u8,
        operation: String,
        nonce: String,
        placement_id: String,
        execution_epoch: u64,
        boot_challenge: String,
    }

    #[derive(Serialize)]
    struct Receipt<'a> {
        version: u8,
        state: &'static str,
        nonce: &'a str,
        boot_id: &'a str,
        placement_id: &'a str,
        execution_epoch: u64,
        boot_challenge: &'a str,
    }

    fn valid_hex(value: &str) -> bool {
        value.len() == 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    }

    pub fn run() -> io::Result<()> {
        let (boot, _, _) = lyra::platform::native::identity()?;
        let listener = Listener::bind(PORT, 1)?;
        loop {
            let mut connection = listener.accept()?;
            let mut line = Vec::new();
            let mut reader = BufReader::new(&mut connection);
            reader.read_until(b'\n', &mut line)?;
            if line.len() > MAX_LINE {
                continue;
            }
            let Ok(request) = serde_json::from_slice::<Request>(&line) else {
                continue;
            };
            if request.version != 1
                || request.operation != "sync"
                || !valid_hex(&request.nonce)
                || request.placement_id != boot.placement_id
                || request.execution_epoch != boot.execution_epoch
                || request.boot_challenge != boot.boot_challenge
            {
                continue;
            }
            // SAFETY: libc::sync has no arguments and only requests the OS to
            // flush dirty buffers; it cannot execute guest-provided input.
            unsafe { libc::sync() };
            let receipt = serde_json::to_vec(&Receipt {
                version: 1,
                state: "flushed",
                nonce: &request.nonce,
                boot_id: &boot.boot_id,
                placement_id: &boot.placement_id,
                execution_epoch: boot.execution_epoch,
                boot_challenge: &boot.boot_challenge,
            })
            .map_err(io::Error::other)?;
            if receipt.len() + 1 <= MAX_LINE {
                connection.write_all(&receipt)?;
                connection.write_all(b"\n")?;
            }
        }
    }
}

#[cfg(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris"))]
fn main() -> ! {
    std::process::exit(match daemon::run() {
        Ok(()) => 0,
        Err(_) => 1,
    });
}

#[cfg(not(any(target_os = "freebsd", target_os = "illumos", target_os = "solaris")))]
fn main() -> ! {
    std::process::exit(64);
}

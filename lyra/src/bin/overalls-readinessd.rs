//! Windows guest boot readiness daemon (ADR-0171, gate 2).
//!
//! The Windows counterpart of the Linux `lilly-readiness` service: it binds
//! this boot's identity from MMDS and the volatile boot UUID, listens on vsock
//! port 1024 and answers Lilly's poll with the closed six-key `ready` line only
//! when the live probes pass: the delivered `/32` and routes are configured,
//! every required service is RUNNING, `sshd` is RUNNING once the SSH agent has
//! published its `ssh-ready` marker, and `C:` accepts a durable write. It has
//! no execution, transfer or cleanup authority and ingests nothing from the
//! peer. Runs as a SYSTEM task; exits 64 on other operating systems.

#[cfg(windows)]
mod daemon {
    use lyra::guest::mmds;
    use lyra::guest::readiness::{self, Boot, Probe};
    use lyra::platform::windows::log::Logger;
    use lyra::platform::windows::vsock::{self, Listener, HOST_CID};
    use lyra::platform::windows::{boot_id, net, services};
    use std::fs::{self, OpenOptions};
    use std::io::{self, Write};
    use std::net::Ipv4Addr;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant};

    const IDENTITY_BUDGET: Duration = Duration::from_secs(600);
    const RUN_DIR: &str = "C:\\overalls\\run";
    const SSH_READY: &str = "C:\\overalls\\run\\ssh-ready";
    const SSHD: &str = "sshd";
    /// Services that must be RUNNING before the guest is ready, besides sshd:
    /// the network store and the TCP/IP stack. The DHCP client is not required
    /// because the bootstrap task configures the address statically.
    const REQUIRED: &[&str] = &["nsi", "Tcpip"];

    struct Live {
        address: Ipv4Addr,
        gateway: Ipv4Addr,
        logger: Logger,
    }

    impl Live {
        /// @cc [owner:ghuntley,label:recovery] windows-readiness-live-probes
        /// Every answer MUST re-check the delivered /32 and routes, every required
        /// service, sshd once the ssh-ready marker exists, and a synced write on
        /// C:; a failed or erroring probe withholds the answer.
        fn probe(&mut self) -> io::Result<bool> {
            if !net::configured(self.address, self.gateway)? {
                self.logger.log("probe_network_pending");
                return Ok(false);
            }
            for name in REQUIRED {
                if !services::running(name)? {
                    self.logger.log("probe_service_pending");
                    return Ok(false);
                }
            }
            if boot_id::marker_is_current(Path::new(SSH_READY)) && !services::running(SSHD)? {
                self.logger.log("probe_sshd_pending");
                return Ok(false);
            }
            writable_root()?;
            Ok(true)
        }
    }

    impl Probe for Live {
        fn ready(&mut self) -> io::Result<bool> {
            self.probe()
        }
    }

    /// Create, sync and remove a file on the system volume itself.
    fn writable_root() -> io::Result<()> {
        fs::create_dir_all(RUN_DIR)?;
        let path: PathBuf = Path::new(RUN_DIR).join(format!(".readiness-{}", std::process::id()));
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)?;
        file.write_all(b"ready\n")?;
        file.sync_all()?;
        drop(file);
        fs::remove_file(&path)
    }

    fn identity(logger: &Logger) -> io::Result<(Boot, Ipv4Addr, Ipv4Addr)> {
        let started = Instant::now();
        let document = loop {
            match mmds::fetch(Duration::from_secs(5)) {
                Ok(document) => break document,
                Err(_) if started.elapsed() < IDENTITY_BUDGET => {
                    std::thread::sleep(Duration::from_secs(2));
                }
                Err(error) => return Err(error),
            }
        };
        let address: Ipv4Addr = document
            .ipv4
            .parse()
            .map_err(|_| io::Error::other("invalid address"))?;
        let gateway: Ipv4Addr = document
            .gateway
            .parse()
            .map_err(|_| io::Error::other("invalid gateway"))?;
        let boot = Boot::new(
            document.placement,
            document.execution_epoch,
            document.boot_challenge,
            boot_id::boot_id()?,
        )?;
        logger.log("identity_bound");
        Ok((boot, address, gateway))
    }

    pub fn run() -> i32 {
        let logger = Logger::new("readinessd");
        logger.log("start");
        if let Err(error) = vsock::startup() {
            logger.log(&format!(
                "winsock_unavailable code={}",
                error.raw_os_error().unwrap_or(0)
            ));
            logger.publish();
            return 1;
        }
        let (boot, address, gateway) = match identity(&logger) {
            Ok(identity) => identity,
            Err(error) => {
                logger.log(&format!("identity_unavailable kind={:?}", error.kind()));
                logger.publish();
                return 2;
            }
        };
        let family = match vsock::discover(IDENTITY_BUDGET, |_| {}) {
            Ok(family) => family,
            Err(error) => {
                logger.log(&format!("vsock_unavailable kind={:?}", error.kind()));
                logger.publish();
                return 3;
            }
        };
        let listener = match Listener::bind(family, readiness::PORT, 4) {
            Ok(listener) => listener,
            Err(error) => {
                logger.log(&format!(
                    "bind_failed code={}",
                    error.raw_os_error().unwrap_or(0)
                ));
                logger.publish();
                return 4;
            }
        };
        logger.log(&format!(
            "listening port={} family={}",
            readiness::PORT,
            family.number
        ));
        logger.publish();
        let mut live = Live {
            address,
            gateway,
            logger: logger.clone(),
        };
        let mut answered = false;
        loop {
            let mut connection = match listener.accept(Duration::from_secs(2)) {
                Ok(connection) => connection,
                Err(_) => {
                    std::thread::sleep(Duration::from_millis(200));
                    continue;
                }
            };
            match readiness::answer(connection.peer_cid, HOST_CID, &boot, &mut live) {
                Ok(Some(line)) => {
                    if connection.write_all(&line).is_ok() && !answered {
                        answered = true;
                        logger.log("ready_answered");
                        logger.publish();
                    }
                }
                Ok(None) => {}
                Err(error) => logger.log(&format!("probe_error kind={:?}", error.kind())),
            }
        }
    }
}

#[cfg(windows)]
fn main() {
    std::process::exit(daemon::run());
}

#[cfg(not(windows))]
fn main() {
    eprintln!("overalls-readinessd runs inside Windows guests only");
    std::process::exit(64);
}

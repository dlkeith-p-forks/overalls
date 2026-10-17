//! Disposable webhook fixture; production delivery uses upstream Alertmanager.
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;

const ROOT: &str = "/var/lib/burn-webhook";
const LIMIT: usize = 131_072;

/// @cc [owner:ghuntley,label:verification;security] burn-fixture-bounded-intake
/// The isolated receiver MUST bound headers/body, require the synthetic bearer
/// credential and record only accepted requests; simulated outage MUST return 503.
fn handle(stream: &mut TcpStream) -> io::Result<()> {
    stream.set_read_timeout(Some(std::time::Duration::from_secs(5)))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut line = String::new();
    reader.by_ref().take(4097).read_line(&mut line)?;
    if line.len() > 4096 || !line.starts_with("POST /notify HTTP/1.") {
        return response(stream, 400);
    }
    let mut length: Option<usize> = None;
    let mut authorized = false;
    let mut header_bytes = line.len();
    loop {
        line.clear();
        reader.by_ref().take(4097).read_line(&mut line)?;
        header_bytes += line.len();
        if line.is_empty() || line.len() > 4096 || header_bytes > 16_384 {
            return response(stream, 400);
        }
        if line == "\r\n" {
            break;
        }
        if let Some((key, value)) = line.split_once(':') {
            match key.to_ascii_lowercase().as_str() {
                "content-length" => {
                    if length.is_some() {
                        return response(stream, 400);
                    }
                    length = value.trim().parse().ok();
                }
                "authorization" => authorized = value.trim() == "Bearer synthetic-delivery-token",
                _ => {}
            }
        }
    }
    let Some(size) = length.filter(|size| *size > 0 && *size <= LIMIT) else {
        return response(stream, 400);
    };
    if !authorized {
        return response(stream, 403);
    }
    let mut body = vec![0; size];
    reader.read_exact(&mut body)?;
    if Path::new(ROOT).join("reject").exists() {
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(Path::new(ROOT).join("attempts"))?
            .write_all(b"rejected\n")?;
        return response(stream, 503);
    }
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(Path::new(ROOT).join("received.jsonl"))?;
    file.write_all(&body)?;
    if !body.ends_with(b"\n") {
        file.write_all(b"\n")?;
    }
    file.sync_all()?;
    response(stream, 200)
}

fn response(stream: &mut TcpStream, status: u16) -> io::Result<()> {
    write!(
        stream,
        "HTTP/1.1 {status} Fixture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    )
}

fn main() -> io::Result<()> {
    fs::create_dir_all(ROOT)?;
    let listener = TcpListener::bind("127.0.0.1:18080")?;
    for stream in listener.incoming() {
        if let Ok(mut stream) = stream {
            let _ = handle(&mut stream);
        }
    }
    Ok(())
}

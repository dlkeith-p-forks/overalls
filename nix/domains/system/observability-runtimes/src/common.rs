use std::io::{Read, Write};
use std::net::TcpListener;

pub fn serve(address: &str, port: u16, metrics: impl Fn() -> String) -> std::io::Result<()> {
    let listener = TcpListener::bind((address, port))?;
    for stream in listener.incoming() {
        let mut stream = stream?;
        let mut request = [0u8; 4096];
        let size = stream.read(&mut request)?;
        let request = String::from_utf8_lossy(&request[..size]);
        let is_metrics = request.starts_with("GET /metrics HTTP/");
        let body = if is_metrics { metrics() } else { String::new() };
        let status = if is_metrics {
            "200 OK"
        } else {
            "404 Not Found"
        };
        write!(stream, "HTTP/1.1 {status}\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body)?;
    }
    Ok(())
}

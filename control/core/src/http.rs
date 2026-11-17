//! A minimal HTTP/1.1 GET against the services on loopback. Both listen only on 127.0.0.1
//! (TLS ends at Tailscale), so no TLS library is needed and nothing leaves the computer.

use std::io::{Read as _, Write as _};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

/// Largest body read; the status answers are a few kilobytes.
const MAX_BODY: usize = 256 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HttpError {
    /// Nothing listens on the port (service stopped).
    Refused,
    /// No answer within the timeout (service starting or stuck).
    TimedOut,
    /// An answer that is not HTTP or is too large.
    Invalid,
    /// Something other than the service listens on its port; the token is not sent.
    Untrusted,
}

impl std::fmt::Display for HttpError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            HttpError::Refused => "Ingen kontakt.",
            HttpError::TimedOut => "Svarar inte.",
            HttpError::Invalid => "Ogiltigt svar.",
            HttpError::Untrusted => "Porten används av ett annat program.",
        })
    }
}

impl std::error::Error for HttpError {}

/// GET `path` on `127.0.0.1:port`. `bearer` is sent as `Authorization`; it never appears in errors.
pub fn get(port: u16, path: &str, bearer: Option<&str>, timeout: Duration) -> Result<Response, HttpError> {
    let address = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let mut stream = TcpStream::connect_timeout(&address, timeout).map_err(|error| match error.kind() {
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => HttpError::TimedOut,
        _ => HttpError::Refused,
    })?;
    stream.set_read_timeout(Some(timeout)).map_err(|_| HttpError::Invalid)?;
    stream.set_write_timeout(Some(timeout)).map_err(|_| HttpError::Invalid)?;
    let mut request = format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAccept: application/json\r\nConnection: close\r\n");
    if let Some(token) = bearer {
        request.push_str(&format!("Authorization: Bearer {token}\r\n"));
    }
    request.push_str("\r\n");
    stream.write_all(request.as_bytes()).map_err(|_| HttpError::Refused)?;
    let mut raw = Vec::new();
    stream.take((MAX_BODY + 16 * 1024) as u64).read_to_end(&mut raw).map_err(|error| match error.kind() {
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => HttpError::TimedOut,
        _ => HttpError::Invalid,
    })?;
    parse_response(&raw)
}

/// Parses a complete response read until the server closed the connection.
pub fn parse_response(raw: &[u8]) -> Result<Response, HttpError> {
    let split = raw.windows(4).position(|window| window == b"\r\n\r\n").ok_or(HttpError::Invalid)?;
    let head = std::str::from_utf8(&raw[..split]).map_err(|_| HttpError::Invalid)?;
    let mut lines = head.split("\r\n");
    let status_line = lines.next().ok_or(HttpError::Invalid)?;
    let mut parts = status_line.split(' ');
    if !parts.next().is_some_and(|version| version.starts_with("HTTP/1.")) {
        return Err(HttpError::Invalid);
    }
    let status = parts.next().and_then(|code| code.parse::<u16>().ok()).ok_or(HttpError::Invalid)?;
    let header = |name: &str| {
        lines
            .clone()
            .filter_map(|line| line.split_once(':'))
            .find(|(key, _)| key.trim().eq_ignore_ascii_case(name))
            .map(|(_, value)| value.trim().to_owned())
    };
    let mut body = raw[split + 4..].to_vec();
    if header("transfer-encoding").is_some_and(|value| value.eq_ignore_ascii_case("chunked")) {
        body = dechunk(&body)?;
    } else if let Some(length) = header("content-length").and_then(|value| value.parse::<usize>().ok()) {
        if body.len() < length {
            return Err(HttpError::Invalid);
        }
        body.truncate(length);
    }
    if body.len() > MAX_BODY {
        return Err(HttpError::Invalid);
    }
    Ok(Response { status, body })
}

fn dechunk(mut data: &[u8]) -> Result<Vec<u8>, HttpError> {
    let mut body = Vec::new();
    loop {
        let end = data.windows(2).position(|window| window == b"\r\n").ok_or(HttpError::Invalid)?;
        let size_text = std::str::from_utf8(&data[..end]).map_err(|_| HttpError::Invalid)?;
        let size = usize::from_str_radix(size_text.split(';').next().unwrap_or("").trim(), 16).map_err(|_| HttpError::Invalid)?;
        data = &data[end + 2..];
        if size == 0 {
            return Ok(body);
        }
        if data.len() < size + 2 || body.len() + size > MAX_BODY {
            return Err(HttpError::Invalid);
        }
        body.extend_from_slice(&data[..size]);
        data = &data[size + 2..];
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn content_length_and_chunked_bodies() {
        let plain = parse_response(b"HTTP/1.1 200 OK\r\ncontent-length: 15\r\n\r\n{\"status\":\"ok\"}").unwrap();
        assert_eq!((plain.status, plain.body.as_slice()), (200, &b"{\"status\":\"ok\"}"[..]));
        let chunked = parse_response(b"HTTP/1.1 503 Service Unavailable\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n").unwrap();
        assert_eq!((chunked.status, chunked.body.as_slice()), (503, &b"{\"a\":1}"[..]));
        assert_eq!(parse_response(b"garbage"), Err(HttpError::Invalid));
        assert_eq!(parse_response(b"HTTP/1.1 200 OK\r\ncontent-length: 99\r\n\r\nshort"), Err(HttpError::Invalid));
    }

    #[test]
    fn a_request_reaches_loopback_with_the_bearer_token() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let read = stream.read(&mut request).unwrap();
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}").unwrap();
            String::from_utf8_lossy(&request[..read]).into_owned()
        });
        let response = get(port, "/v2/status", Some("hemlig"), Duration::from_secs(2)).unwrap();
        assert_eq!((response.status, response.body.as_slice()), (200, &b"{}"[..]));
        let request = server.join().unwrap();
        assert!(request.starts_with("GET /v2/status HTTP/1.1\r\n") && request.contains("Authorization: Bearer hemlig\r\n"));
    }

    #[test]
    fn a_closed_port_is_refused() {
        let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        assert_eq!(get(port, "/health", None, Duration::from_millis(500)), Err(HttpError::Refused));
    }
}

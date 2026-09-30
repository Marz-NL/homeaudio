// A minimal, blocking HTTP/1.1 client for talking to Music Assistant's plain
// http:// local API. Not general-purpose - no TLS, no redirects, no chunked
// transfer-encoding - Music Assistant serves a simple JSON API on the LAN,
// and pulling in a full HTTP client crate for one POST would work against
// the "as light as possible" goal of this whole project.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

pub fn post_json(
    url: &str,
    bearer: Option<&str>,
    body: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    let (host, port, path) = parse_url(url)?;
    let body_bytes = serde_json::to_vec(body).map_err(|e| e.to_string())?;

    let mut stream = TcpStream::connect((host.as_str(), port)).map_err(|e| e.to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .ok();
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .ok();

    let mut req = format!(
        "POST {path} HTTP/1.1\r\nHost: {host}:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n",
        body_bytes.len()
    );
    if let Some(token) = bearer {
        req.push_str(&format!("Authorization: Bearer {token}\r\n"));
    }
    req.push_str("\r\n");

    stream.write_all(req.as_bytes()).map_err(|e| e.to_string())?;
    stream.write_all(&body_bytes).map_err(|e| e.to_string())?;

    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&raw);
    let (status_line, rest) = text.split_once("\r\n").ok_or("empty response")?;
    if !status_line.contains("200") {
        return Err(format!("HTTP error: {status_line}"));
    }
    let body_str = rest.split_once("\r\n\r\n").map(|(_, b)| b).unwrap_or(rest);
    serde_json::from_str(body_str).map_err(|e| format!("bad JSON from server: {e}"))
}

fn parse_url(url: &str) -> Result<(String, u16, String), String> {
    let rest = url
        .strip_prefix("http://")
        .ok_or("only http:// urls are supported")?;
    let (authority, path) = rest
        .split_once('/')
        .map(|(a, p)| (a, format!("/{p}")))
        .unwrap_or((rest, "/".to_string()));
    let (host, port) = authority
        .split_once(':')
        .map(|(h, p)| (h.to_string(), p.parse().unwrap_or(80)))
        .unwrap_or((authority.to_string(), 80));
    Ok((host, port, path))
}

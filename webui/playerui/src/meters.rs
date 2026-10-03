// Live output levels, read from CamillaDSP. CamillaDSP only runs while a
// stream plays, and the cdsp ALSA plugin starts it with its websocket on
// 127.0.0.1:5678 (see lib/output.sh in homeaudio's installer). This thread
// follows that socket: it connects whenever CamillaDSP is up, asks for the
// levels since the last ask ten times a second, and keeps the newest answer
// for the page to read through /meters. Only the websocket that's needed here
// is spoken (one client, text frames, no extensions), so playerui gains no
// new crate.

use serde::Serialize;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const CDSP_PORT: u16 = 5678;
// What a silent channel reports (CamillaDSP sends -inf, which JSON can't hold)
const FLOOR_DB: f32 = -120.0;

#[derive(Serialize, Clone, Default)]
pub struct Levels {
    pub playback_peak: Vec<f32>,
    pub playback_rms: Vec<f32>,
    pub capture_peak: Vec<f32>,
    pub capture_rms: Vec<f32>,
}

// None while CamillaDSP isn't running (nothing is playing through it)
pub type MeterState = Arc<Mutex<Option<Levels>>>;

pub fn spawn(state: MeterState) {
    std::thread::spawn(move || loop {
        // Any failure just means "no levels right now": clear and retry
        let _ = run_session(&state);
        *state.lock().unwrap() = None;
        std::thread::sleep(Duration::from_secs(1));
    });
}

// The /meters response: {"available": false} when nothing is playing through CamillaDSP
pub fn snapshot(state: &MeterState) -> serde_json::Value {
    match state.lock().unwrap().clone() {
        Some(l) => serde_json::json!({
            "available": true,
            "playback": { "peak": l.playback_peak, "rms": l.playback_rms },
            "capture": { "peak": l.capture_peak, "rms": l.capture_rms },
        }),
        None => serde_json::json!({ "available": false }),
    }
}

fn run_session(state: &MeterState) -> std::io::Result<()> {
    let mut s = TcpStream::connect(("127.0.0.1", CDSP_PORT))?;
    s.set_read_timeout(Some(Duration::from_secs(2)))?;
    s.set_write_timeout(Some(Duration::from_secs(2)))?;
    handshake(&mut s)?;
    loop {
        send_text(&mut s, "\"GetSignalLevelsSinceLast\"")?;
        let text = recv_text(&mut s)?;
        if let Some(levels) = parse_levels(&text) {
            *state.lock().unwrap() = Some(levels);
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn handshake(s: &mut TcpStream) -> std::io::Result<()> {
    // Local connection, nothing to authenticate: the key only has to be well formed
    s.write_all(
        b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
    )?;
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        s.read_exact(&mut byte)?;
        head.push(byte[0]);
        if head.len() > 4096 {
            return Err(std::io::Error::other("websocket handshake too long"));
        }
    }
    if !head.starts_with(b"HTTP/1.1 101") {
        return Err(std::io::Error::other("CamillaDSP did not accept the websocket"));
    }
    Ok(())
}

// A client frame must be masked. The mask only has to be unpredictable to a
// proxy, which a 127.0.0.1 connection never has, so the clock's nanoseconds do.
fn send_text(s: &mut TcpStream, text: &str) -> std::io::Result<()> {
    let data = text.as_bytes();
    let mask = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().subsec_nanos().to_be_bytes();
    let mut frame = vec![0x81];
    match data.len() {
        n if n < 126 => frame.push(0x80 | n as u8),
        n if n <= u16::MAX as usize => {
            frame.push(0x80 | 126);
            frame.extend_from_slice(&(n as u16).to_be_bytes());
        }
        n => {
            frame.push(0x80 | 127);
            frame.extend_from_slice(&(n as u64).to_be_bytes());
        }
    }
    frame.extend_from_slice(&mask);
    frame.extend(data.iter().enumerate().map(|(i, b)| b ^ mask[i % 4]));
    s.write_all(&frame)
}

// Server frames are not masked. Only text replies are expected: a close, a
// ping, or anything else makes the session end, and the thread reconnects.
fn recv_text(s: &mut TcpStream) -> std::io::Result<String> {
    let mut head = [0u8; 2];
    s.read_exact(&mut head)?;
    if head[0] & 0x0f != 0x1 {
        return Err(std::io::Error::other("unexpected websocket frame"));
    }
    let len = match head[1] & 0x7f {
        126 => {
            let mut b = [0u8; 2];
            s.read_exact(&mut b)?;
            u16::from_be_bytes(b) as usize
        }
        127 => {
            let mut b = [0u8; 8];
            s.read_exact(&mut b)?;
            u64::from_be_bytes(b) as usize
        }
        n => n as usize,
    };
    let mut payload = vec![0u8; len];
    s.read_exact(&mut payload)?;
    String::from_utf8(payload).map_err(std::io::Error::other)
}

// {"GetSignalLevelsSinceLast": {"result": "Ok", "value": {"playback_peak": [dB, ...], ...}}}
fn parse_levels(text: &str) -> Option<Levels> {
    let v: serde_json::Value = serde_json::from_str(text).ok()?;
    let reply = &v["GetSignalLevelsSinceLast"];
    if reply["result"] != "Ok" {
        return None;
    }
    let value = &reply["value"];
    let channels = |key: &str| -> Vec<f32> {
        value[key]
            .as_array()
            .map(|a| a.iter().map(|x| x.as_f64().map_or(FLOOR_DB, |f| (f as f32).max(FLOOR_DB))).collect())
            .unwrap_or_default()
    };
    Some(Levels {
        playback_peak: channels("playback_peak"),
        playback_rms: channels("playback_rms"),
        capture_peak: channels("capture_peak"),
        capture_rms: channels("capture_rms"),
    })
}

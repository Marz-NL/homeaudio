// Wire protocol between playerui (unprivileged, LAN-facing) and player-guard-helper
// (root, Unix-socket-only). One JSON value per line, one request per connection:
// playerui writes a Request, helper writes back one Response, connection closes.
//
// The helper is the only thing in this system with elevated privilege - it enforces
// its own allowlists (which units may be toggled, which config keys may be written,
// which job recipes exist and what parameters they accept) independently of whatever
// playerui thinks it's allowed to ask for.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ServiceVerb {
    Enable,
    Disable,
    /// Allowed even for a non-toggleable unit (e.g. player-guard after a
    /// config change) - restarting a "must stay running" unit is a much
    /// narrower, safer capability than being able to enable/disable it.
    Restart,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum JobRecipe {
    AddQobuz,
    AddSpotify,
    AddAirplay2,
    /// Connect the room to Music Assistant: sendspin + the player id, by
    /// install.sh add ma (needs MA_URL and MA_TOKEN).
    AddMusicAssistant,
}

impl JobRecipe {
    pub fn label(&self) -> &'static str {
        match self {
            JobRecipe::AddQobuz => "Qobuz Connect",
            JobRecipe::AddSpotify => "Spotify Connect",
            JobRecipe::AddAirplay2 => "AirPlay 2",
            JobRecipe::AddMusicAssistant => "Music Assistant",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Request {
    /// Enable or disable a known systemd unit.
    ServiceAction { unit: String, action: ServiceVerb },
    /// Write one field of a known, curated config schema (e.g. player-guard.env's
    /// MA_URL/MA_TOKEN/MA_PLAYER) and restart whatever service reads it.
    WriteConfig {
        service: String,
        key: String,
        value: String,
    },
    /// Kick off a source-install recipe (a real compile, several minutes). Only one
    /// job may run at a time per host.
    RunJob {
        recipe: JobRecipe,
        params: HashMap<String, String>,
    },
    /// Poll a running/finished job's output since a given line offset.
    JobLog { job_id: String, since: usize },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Response {
    Ok,
    Error { message: String },
    JobStarted { job_id: String },
    JobLog {
        lines: Vec<String>,
        next_offset: usize,
        running: bool,
        exit_ok: Option<bool>,
    },
}

/// Send one request and read back one response, over a fresh connection.
pub fn call(socket_path: &str, req: &Request) -> io::Result<Response> {
    let mut stream = UnixStream::connect(socket_path)?;
    let mut line = serde_json::to_string(req).map_err(io::Error::other)?;
    line.push('\n');
    stream.write_all(line.as_bytes())?;
    stream.flush()?;
    let mut reader = BufReader::new(stream);
    let mut buf = String::new();
    reader.read_line(&mut buf)?;
    serde_json::from_str(&buf).map_err(io::Error::other)
}

/// Read one request line from an accepted connection (helper side).
pub fn read_request(stream: &UnixStream) -> io::Result<Request> {
    let mut reader = BufReader::new(stream);
    let mut buf = String::new();
    reader.read_line(&mut buf)?;
    serde_json::from_str(&buf).map_err(io::Error::other)
}

/// Write one response line to an accepted connection (helper side).
pub fn write_response(mut stream: &UnixStream, resp: &Response) -> io::Result<()> {
    let mut line = serde_json::to_string(resp).map_err(io::Error::other)?;
    line.push('\n');
    stream.write_all(line.as_bytes())
}

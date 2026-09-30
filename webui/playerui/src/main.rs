// playerui: the unprivileged, LAN-facing half of the player control panel.
// Reads status directly (systemctl queries, state files - nothing here needs
// elevation), and forwards every privileged action (toggling a unit, writing
// config, running a build job) to player-guard-helper over a Unix socket.
// See helper/src/main.rs for what's actually allowed to happen.


use protocol::{JobRecipe, Request, Response, ServiceVerb};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::process::Command;
use tiny_http::{Header, Method, Server};

#[derive(Debug, Deserialize, Clone)]
struct ServiceConfig {
    id: String,
    name: String,
    unit: String,
    toggleable: bool,
}

#[derive(Debug, Deserialize, Clone)]
struct MusicAssistantConfig {
    env_file: String,
}

#[derive(Debug, Deserialize, Clone, Default)]
struct JobPaths {
    add_qobuz: Option<String>,
    add_spotify: Option<String>,
    add_airplay2: Option<String>,
    add_ma: Option<String>,
}

fn default_socket() -> String {
    "/run/player-guard/helper.sock".to_string()
}

#[derive(Debug, Deserialize, Clone)]
struct Manifest {
    room: String,
    audio_owner_file: String,
    #[serde(default)]
    now_playing_file: Option<String>,
    #[serde(default = "default_socket")]
    helper_socket: String,
    music_assistant: MusicAssistantConfig,
    #[serde(default)]
    service: Vec<ServiceConfig>,
    #[serde(default)]
    jobs: JobPaths,
    /// Base URLs of every room's playerui (this one included), for the
    /// multiroom-in-one-page view. Empty means "just show this room" - the
    /// frontend then fetches its own /status with a relative URL.
    #[serde(default)]
    rooms: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize, Default, Clone)]
struct NowPlaying {
    source: String,
    title: String,
    artist: String,
    #[serde(default)]
    album: String,
    cover: String,
}

#[derive(Debug, Serialize)]
struct ServiceStatus {
    id: String,
    name: String,
    active: bool,
    enabled: bool,
    toggleable: bool,
}

#[derive(Debug, Serialize)]
struct MaStatus {
    /// MA_URL, MA_TOKEN and MA_PLAYER are all set
    configured: bool,
    /// sendspin (this room's Music Assistant player) is installed
    installed: bool,
    /// the Music Assistant address, for display
    url: Option<String>,
    /// the manifest has an add_ma job, so the page can set it up
    can_setup: bool,
}

#[derive(Debug, Serialize)]
struct AvailableJob {
    recipe: JobRecipe,
    label: &'static str,
}

#[derive(Debug, Serialize)]
struct StatusResponse {
    room: String,
    dac_owner: String,
    now_playing: Option<NowPlaying>,
    music_assistant: MaStatus,
    services: Vec<ServiceStatus>,
    available_jobs: Vec<AvailableJob>,
    rooms: Vec<String>,
}

const INDEX_HTML: &str = include_str!("../static/index.html");

fn systemctl_query(unit: &str, query: &str) -> bool {
    Command::new("systemctl")
        .args([query, unit])
        .output()
        .map(|o| {
            let out = String::from_utf8_lossy(&o.stdout);
            let out = out.trim();
            out == "active" || out == "enabled"
        })
        .unwrap_or(false)
}

fn read_dac_owner(path: &str) -> String {
    std::fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "none".to_string())
}

fn read_now_playing(path: &Option<String>) -> Option<NowPlaying> {
    let path = path.as_ref()?;
    let text = std::fs::read_to_string(path).ok()?;
    let np: NowPlaying = serde_json::from_str(&text).ok()?;
    if np.source.is_empty() {
        None
    } else {
        Some(np)
    }
}

fn read_env_file(path: &str) -> HashMap<String, String> {
    let mut env = HashMap::new();
    if let Ok(text) = std::fs::read_to_string(path) {
        for line in text.lines() {
            if let Some((k, v)) = line.split_once('=') {
                if !k.starts_with('#') {
                    env.insert(k.trim().to_string(), v.trim().to_string());
                }
            }
        }
    }
    env
}

fn ma_status(manifest: &Manifest) -> MaStatus {
    let env = read_env_file(&manifest.music_assistant.env_file);
    let configured = ["MA_URL", "MA_TOKEN", "MA_PLAYER"]
        .iter()
        .all(|k| env.get(*k).is_some_and(|v| !v.is_empty()));
    MaStatus {
        configured,
        installed: std::path::Path::new("/etc/systemd/system/sendspin.service").exists(),
        url: env.get("MA_URL").filter(|v| !v.is_empty()).cloned(),
        can_setup: manifest.jobs.add_ma.is_some(),
    }
}

// Music Assistant servers on the LAN: they announce _mass._tcp over mDNS with
// their address in a base_url TXT record. Read-only, no privilege needed.
fn handle_ma_find() -> tiny_http::ResponseBox {
    let out = Command::new("timeout")
        .args(["6", "avahi-browse", "-rtp", "_mass._tcp"])
        .output();
    let Ok(out) = out else {
        return err_json(500, "avahi-browse is missing (apt install avahi-utils)");
    };
    let mut servers: Vec<serde_json::Value> = vec![];
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        // =;iface;proto;name;type;domain;host;address;port;"k=v" "k=v" ...
        let f: Vec<&str> = line.splitn(10, ';').collect();
        if f.len() < 10 || f[0] != "=" || f[2] != "IPv4" {
            continue;
        }
        let txt = |key: &str| {
            f[9].split("\" \"")
                .map(|kv| kv.trim_matches('"'))
                .find_map(|kv| kv.strip_prefix(&format!("{key}=")))
                .map(str::to_string)
        };
        let url = txt("base_url").unwrap_or_else(|| format!("http://{}:{}", f[7], f[8]));
        if servers.iter().any(|s| s["url"] == url.as_str()) {
            continue;
        }
        let name = txt("name").unwrap_or_else(|| f[3].to_string());
        servers.push(serde_json::json!({"name": name, "url": url}));
    }
    ok_json(serde_json::json!({"servers": servers}))
}

fn available_jobs(manifest: &Manifest) -> Vec<AvailableJob> {
    let have = |id: &str| manifest.service.iter().any(|s| s.id == id);
    let mut out = vec![];
    if !have("pibuz") && manifest.jobs.add_qobuz.is_some() {
        out.push(AvailableJob {
            recipe: JobRecipe::AddQobuz,
            label: "Qobuz Connect",
        });
    }
    if !have("spotifyd") && manifest.jobs.add_spotify.is_some() {
        out.push(AvailableJob {
            recipe: JobRecipe::AddSpotify,
            label: "Spotify Connect",
        });
    }
    if !have("shairport-sync") && manifest.jobs.add_airplay2.is_some() {
        out.push(AvailableJob {
            recipe: JobRecipe::AddAirplay2,
            label: "AirPlay 2",
        });
    }
    out
}

// Rooms announce themselves on the LAN (_homeaudio._tcp, see install.sh);
// refreshed in the background so /status never waits on the network.
type FoundRooms = std::sync::Arc<std::sync::Mutex<Vec<String>>>;

fn discover_rooms_forever(found: FoundRooms) {
    loop {
        if let Ok(out) = Command::new("timeout")
            .args(["6", "avahi-browse", "-rtp", "_homeaudio._tcp"])
            .output()
        {
            let mut urls: Vec<String> = vec![];
            let mut names: Vec<String> = vec![];
            for line in String::from_utf8_lossy(&out.stdout).lines() {
                // =;iface;proto;name;type;domain;host;address;port;txt
                let f: Vec<&str> = line.splitn(10, ';').collect();
                if f.len() < 9 || f[0] != "=" || f[2] != "IPv4" {
                    continue;
                }
                // A host is seen once per interface: keep the LAN one, once
                let virtual_if = ["lo", "docker", "br-", "veth", "virbr", "tailscale", "zt", "wg", "tun"]
                    .iter()
                    .any(|p| f[1].starts_with(p));
                if virtual_if || names.iter().any(|n| n == f[3]) {
                    continue;
                }
                names.push(f[3].to_string());
                urls.push(format!("http://{}:{}", f[7], f[8]));
            }
            urls.sort();
            *found.lock().unwrap() = urls;
        }
        std::thread::sleep(std::time::Duration::from_secs(30));
    }
}

fn build_status(manifest: &Manifest, found: &FoundRooms) -> StatusResponse {
    // Listed rooms first (they keep their order), then the ones found; the
    // page drops a room it reaches twice under two addresses.
    let mut rooms = manifest.rooms.clone();
    for url in found.lock().unwrap().iter() {
        if !rooms.contains(url) {
            rooms.push(url.clone());
        }
    }
    let services = manifest
        .service
        .iter()
        .map(|s| ServiceStatus {
            id: s.id.clone(),
            name: s.name.clone(),
            active: systemctl_query(&s.unit, "is-active"),
            enabled: systemctl_query(&s.unit, "is-enabled"),
            toggleable: s.toggleable,
        })
        .collect();
    StatusResponse {
        room: manifest.room.clone(),
        dac_owner: read_dac_owner(&manifest.audio_owner_file),
        now_playing: read_now_playing(&manifest.now_playing_file),
        music_assistant: ma_status(manifest),
        services,
        available_jobs: available_jobs(manifest),
        rooms,
    }
}

fn json_header() -> Header {
    Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap()
}
fn html_header() -> Header {
    Header::from_bytes(&b"Content-Type"[..], &b"text/html; charset=utf-8"[..]).unwrap()
}
fn cors_header() -> Header {
    // Multiroom-in-one-page: any room's page fetches every other room's
    // /status from the browser directly. No auth exists on this API at all
    // (LAN-trust, matching pibuz's own control API), so an open CORS policy
    // adds no new exposure.
    Header::from_bytes(&b"Access-Control-Allow-Origin"[..], &b"*"[..]).unwrap()
}

fn json_body(request: &mut tiny_http::Request) -> serde_json::Value {
    let mut buf = String::new();
    let _ = request.as_reader().read_to_string(&mut buf);
    serde_json::from_str(&buf).unwrap_or(serde_json::Value::Null)
}

fn err_json(status: u16, message: impl Into<String>) -> tiny_http::ResponseBox {
    let body = serde_json::json!({ "error": message.into() }).to_string();
    tiny_http::Response::from_string(body)
        .with_status_code(status)
        .with_header(json_header())
        .with_header(cors_header())
        .boxed()
}

fn ok_json(value: serde_json::Value) -> tiny_http::ResponseBox {
    tiny_http::Response::from_string(value.to_string())
        .with_header(json_header())
        .with_header(cors_header())
        .boxed()
}

fn helper_call(manifest: &Manifest, req: &Request) -> Result<Response, String> {
    protocol::call(&manifest.helper_socket, req).map_err(|e| e.to_string())
}

fn load_manifest(path: &str) -> Manifest {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("cannot read manifest {path}: {e}");
        std::process::exit(1);
    });
    toml::from_str(&text).unwrap_or_else(|e| {
        eprintln!("cannot parse manifest {path}: {e}");
        std::process::exit(1);
    })
}

fn main() {
    let mut args = std::env::args().skip(1);
    let manifest_path = args
        .next()
        .unwrap_or_else(|| "/etc/player-guard-services.toml".to_string());
    let bind_addr = args.next().unwrap_or_else(|| "0.0.0.0:8189".to_string());

    // Sanity-check the manifest parses before binding, but reload it fresh on
    // every request below - a build job can append a new [[service]] to this
    // file at any time (see player-guard-helper), and playerui should pick
    // that up without needing a restart.
    let startup_check: Manifest = load_manifest(&manifest_path);

    let found: FoundRooms = Default::default();
    {
        let found = found.clone();
        std::thread::spawn(move || discover_rooms_forever(found));
    }

    let server = Server::http(&bind_addr).unwrap_or_else(|e| {
        eprintln!("cannot bind {bind_addr}: {e}");
        std::process::exit(1);
    });
    println!(
        "playerui for {} listening on {bind_addr}",
        startup_check.room
    );
    drop(startup_check);

    for mut request in server.incoming_requests() {
        let manifest = load_manifest(&manifest_path);
        let method = request.method().clone();
        let url = request.url().to_string();

        let response = match (&method, url.split('?').next().unwrap_or("")) {
            (Method::Get, "/") => tiny_http::Response::from_string(INDEX_HTML)
                .with_header(html_header())
                .boxed(),

            (Method::Get, "/status") => ok_json(serde_json::to_value(build_status(&manifest, &found)).unwrap()),

            (Method::Post, path) if path.starts_with("/services/") => {
                let mut parts = path.trim_start_matches("/services/").splitn(2, '/');
                let id = parts.next().unwrap_or("");
                let action = parts.next().unwrap_or("");
                handle_service_toggle(&manifest, id, action)
            }

            (Method::Get, "/music-assistant/find") => handle_ma_find(),

            (Method::Post, path) if path.starts_with("/jobs/") => {
                let recipe_name = path.trim_start_matches("/jobs/");
                handle_run_job(&manifest, recipe_name, &mut request)
            }
            (Method::Get, "/jobs/log") => handle_job_log(&manifest, &url),
            (Method::Get, "/guard-log") => handle_guard_log(&manifest),

            (Method::Options, _) => tiny_http::Response::empty(204)
                .with_header(cors_header())
                .boxed(),

            _ => err_json(404, "not found"),
        };
        let _ = request.respond(response);
    }
}

fn handle_service_toggle(manifest: &Manifest, id: &str, action: &str) -> tiny_http::ResponseBox {
    let Some(svc) = manifest.service.iter().find(|s| s.id == id) else {
        return err_json(404, "unknown service");
    };
    if !svc.toggleable {
        return err_json(403, "this service is not toggleable");
    }
    let verb = match action {
        "enable" => ServiceVerb::Enable,
        "disable" => ServiceVerb::Disable,
        _ => return err_json(400, "action must be enable or disable"),
    };
    let req = Request::ServiceAction {
        unit: svc.unit.clone(),
        action: verb,
    };
    match helper_call(manifest, &req) {
        Ok(Response::Ok) => ok_json(serde_json::json!({"ok": true})),
        Ok(Response::Error { message }) => err_json(500, message),
        Ok(_) => err_json(500, "unexpected helper response"),
        Err(e) => err_json(500, format!("helper unreachable: {e}")),
    }
}

fn handle_run_job(
    manifest: &Manifest,
    recipe_name: &str,
    request: &mut tiny_http::Request,
) -> tiny_http::ResponseBox {
    let recipe = match recipe_name {
        "add-qobuz" => JobRecipe::AddQobuz,
        "add-spotify" => JobRecipe::AddSpotify,
        "add-airplay2" => JobRecipe::AddAirplay2,
        "add-ma" => JobRecipe::AddMusicAssistant,
        _ => return err_json(404, "unknown job recipe"),
    };
    let body = json_body(request);
    let mut params = HashMap::new();
    if let Some(obj) = body.as_object() {
        for (k, v) in obj {
            if let Some(s) = v.as_str() {
                params.insert(k.clone(), s.to_string());
            }
        }
    }
    // Fill in well-known context the underlying scripts need, without
    // overriding anything the caller explicitly set - this is what most of
    // the existing setup scripts actually require (a room NAME, MA_PLAYER
    // for scripts that pair a new room with Music Assistant), and relying
    // on the frontend to remember every script's parameter list per recipe
    // is exactly the kind of thing that quietly goes stale.
    params.entry("NAME".to_string()).or_insert_with(|| manifest.room.clone());
    params
        .entry("AIRPLAY_NAME".to_string())
        .or_insert_with(|| manifest.room.clone());
    if let Some(player) = read_env_file(&manifest.music_assistant.env_file).get("MA_PLAYER") {
        params.entry("MA_PLAYER".to_string()).or_insert_with(|| player.clone());
    }
    match helper_call(manifest, &Request::RunJob { recipe, params }) {
        Ok(Response::JobStarted { job_id }) => ok_json(serde_json::json!({"job_id": job_id})),
        Ok(Response::Error { message }) => err_json(409, message),
        Ok(_) => err_json(500, "unexpected helper response"),
        Err(e) => err_json(500, format!("helper unreachable: {e}")),
    }
}

fn handle_job_log(manifest: &Manifest, url: &str) -> tiny_http::ResponseBox {
    let since: usize = url
        .split_once('?')
        .and_then(|(_, q)| q.split('&').find_map(|p| p.strip_prefix("since=")))
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let req = Request::JobLog {
        job_id: "current".into(),
        since,
    };
    match helper_call(manifest, &req) {
        Ok(Response::JobLog {
            lines,
            next_offset,
            running,
            exit_ok,
        }) => ok_json(serde_json::json!({
            "lines": lines, "next_offset": next_offset, "running": running, "exit_ok": exit_ok
        })),
        Ok(Response::Error { message }) => err_json(500, message),
        Ok(_) => err_json(500, "unexpected helper response"),
        Err(e) => err_json(500, format!("helper unreachable: {e}")),
    }
}

// Read-only, like the systemctl status queries above - no privilege needed
// beyond journal read access (the playerui system user is a member of
// systemd-journal), so this is handled directly rather than through the
// helper. Refetches the last N lines each time rather than tracking an
// incremental cursor - simpler, and re-rendering a short tail on each poll
// is indistinguishable from true streaming for a human watching it.
fn handle_guard_log(manifest: &Manifest) -> tiny_http::ResponseBox {
    let unit = manifest
        .service
        .iter()
        .find(|s| s.id == "player-guard")
        .map(|s| s.unit.as_str())
        .unwrap_or("player-guard");
    let out = Command::new("journalctl")
        .args(["-u", unit, "-n", "150", "--no-pager", "-o", "cat"])
        .output();
    match out {
        Ok(o) if o.status.success() => {
            let lines: Vec<&str> = std::str::from_utf8(&o.stdout)
                .unwrap_or("")
                .lines()
                .collect();
            ok_json(serde_json::json!({ "lines": lines }))
        }
        Ok(o) => err_json(500, String::from_utf8_lossy(&o.stderr).trim().to_string()),
        Err(e) => err_json(500, e.to_string()),
    }
}

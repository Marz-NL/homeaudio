// player-guard-helper: the only privileged part of this system. Runs as root,
// listens on a Unix socket that only the unprivileged playerui user can reach
// (group-owned, see the systemd unit), and enforces its own allowlists for
// every kind of privileged action - which units may be toggled, which config
// keys may be written and how, which job recipes exist and what parameters
// they accept. playerui is a thin, LAN-facing frontend to this; it never
// gets to decide what's allowed, only to ask.

use protocol::{JobRecipe, Request, Response, ServiceVerb};
use serde::Deserialize;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read};
use std::os::unix::net::{UnixListener, UnixStream};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};

#[derive(Debug, Deserialize, Clone)]
struct ServiceConfig {
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

#[derive(Debug, Deserialize, Clone)]
struct Manifest {
    service: Vec<ServiceConfig>,
    music_assistant: MusicAssistantConfig,
    #[serde(default)]
    jobs: JobPaths,
}

struct JobState {
    lines: Vec<String>,
    running: bool,
    exit_ok: Option<bool>,
}

type SharedJob = Arc<Mutex<Option<JobState>>>;

fn main() {
    let mut args = std::env::args().skip(1);
    let manifest_path = args
        .next()
        .unwrap_or_else(|| "/etc/player-guard-services.toml".to_string());
    let socket_path = args
        .next()
        .unwrap_or_else(|| "/run/player-guard/helper.sock".to_string());

    let manifest: Manifest = {
        let text = std::fs::read_to_string(&manifest_path).unwrap_or_else(|e| {
            eprintln!("cannot read manifest {manifest_path}: {e}");
            std::process::exit(1);
        });
        toml::from_str(&text).unwrap_or_else(|e| {
            eprintln!("cannot parse manifest {manifest_path}: {e}");
            std::process::exit(1);
        })
    };

    let _ = std::fs::remove_file(&socket_path);
    let listener = UnixListener::bind(&socket_path).unwrap_or_else(|e| {
        eprintln!("cannot bind {socket_path}: {e}");
        std::process::exit(1);
    });
    // group-readable/writable so the unprivileged playerui user (in the
    // audioguard group) can connect, unreachable by anyone else on the box.
    let _ = Command::new("chgrp").arg("audioguard").arg(&socket_path).status();
    let _ = Command::new("chmod").arg("660").arg(&socket_path).status();

    let job: SharedJob = Arc::new(Mutex::new(None));

    println!("player-guard-helper listening on {socket_path}");
    for conn in listener.incoming() {
        let Ok(stream) = conn else { continue };
        let manifest = manifest.clone();
        let manifest_path = manifest_path.clone();
        let job = job.clone();
        std::thread::spawn(move || handle(stream, &manifest, &manifest_path, job));
    }
}

fn handle(stream: UnixStream, manifest: &Manifest, manifest_path: &str, job: SharedJob) {
    let req = match protocol::read_request(&stream) {
        Ok(r) => r,
        Err(_) => return,
    };
    let resp = dispatch(req, manifest, manifest_path, &job);
    let _ = protocol::write_response(&stream, &resp);
}

fn dispatch(req: Request, manifest: &Manifest, manifest_path: &str, job: &SharedJob) -> Response {
    match req {
        Request::ServiceAction { unit, action } => service_action(&unit, action, manifest),
        Request::WriteConfig {
            service,
            key,
            value,
        } => write_config(&service, &key, &value, manifest),
        Request::RunJob { recipe, params } => run_job(recipe, params, manifest, manifest_path, job),
        Request::JobLog { since, .. } => job_log(since, job),
    }
}

fn service_action(unit: &str, action: ServiceVerb, manifest: &Manifest) -> Response {
    let entry = manifest.service.iter().find(|s| s.unit == unit);
    let allowed = match (&action, entry) {
        (ServiceVerb::Restart, Some(_)) => true, // restart is fine even when not toggleable
        (_, Some(s)) => s.toggleable,
        (_, None) => false,
    };
    if !allowed {
        return Response::Error {
            message: format!("{unit} does not accept this action"),
        };
    }
    let verb = match action {
        ServiceVerb::Enable => "enable",
        ServiceVerb::Disable => "disable",
        ServiceVerb::Restart => "restart",
    };
    let args: &[&str] = if matches!(action, ServiceVerb::Restart) {
        &[verb, unit]
    } else {
        &[verb, "--now", unit]
    };
    match Command::new("systemctl").args(args).output() {
        Ok(out) if out.status.success() => Response::Ok,
        Ok(out) => Response::Error {
            message: String::from_utf8_lossy(&out.stderr).trim().to_string(),
        },
        Err(e) => Response::Error {
            message: e.to_string(),
        },
    }
}

// Curated config schema: service name -> which keys are writable and how.
// This is the first case of "everything in .env/.yaml should be in the UI" -
// extend this match as more of that gets built out.
fn write_config(service: &str, key: &str, value: &str, manifest: &Manifest) -> Response {
    match service {
        "music-assistant" => write_player_guard_env(key, value, &manifest.music_assistant.env_file),
        _ => Response::Error {
            message: format!("unknown config service: {service}"),
        },
    }
}

fn write_player_guard_env(key: &str, value: &str, path: &str) -> Response {
    const ALLOWED: &[&str] = &["MA_URL", "MA_TOKEN", "MA_PLAYER"];
    if !ALLOWED.contains(&key) {
        return Response::Error {
            message: format!("{key} is not a writable player-guard.env key"),
        };
    }
    // This file is not just parsed, it's `source`d as shell by player-guard
    // and the ma-stop/ma-pause/ma-play helpers, on essentially every play/
    // pause/stop handover. A value containing a newline (or shell
    // metacharacters) would inject an executable line, run as root the next
    // time anything sources it - so only a narrow, deliberately safe
    // charset is allowed: what a URL, a JWT and a player id actually need.
    if value.is_empty() || !value.chars().all(|c| c.is_ascii_alphanumeric() || "./:_-".contains(c)) {
        return Response::Error {
            message: format!("{key}'s value contains characters that aren't safe in a sourced shell file"),
        };
    }
    let existing = std::fs::read_to_string(path).unwrap_or_default();
    let mut found = false;
    let mut out: Vec<String> = existing
        .lines()
        .map(|line| {
            if line.starts_with(&format!("{key}=")) {
                found = true;
                format!("{key}={value}")
            } else {
                line.to_string()
            }
        })
        .collect();
    if !found {
        out.push(format!("{key}={value}"));
    }
    // Just the write here - restarting whatever reads this file is a
    // separate ServiceAction::Restart call, made once after all the
    // fields of a form are written, not after each individual field.
    match std::fs::write(path, out.join("\n") + "\n") {
        Ok(()) => Response::Ok,
        Err(e) => Response::Error {
            message: e.to_string(),
        },
    }
}

// Job recipes: each maps to a script path from the manifest and a fixed set
// of accepted parameter names. Unlisted parameters are dropped, never passed
// through, so a request can't smuggle arbitrary environment into the build.
// What a successful recipe run adds to the manifest, so it shows up as a
// real toggle afterward instead of requiring a manual TOML edit.
// The [[service]] toggle a successful job adds. Music Assistant isn't a toggle
// (sendspin always runs), so it adds none.
fn recipe_service(recipe: JobRecipe) -> Option<(&'static str, &'static str, &'static str)> {
    match recipe {
        JobRecipe::AddQobuz => Some(("pibuz", "Qobuz Connect", "pibuz")),
        JobRecipe::AddSpotify => Some(("spotifyd", "Spotify Connect", "spotifyd")),
        JobRecipe::AddAirplay2 => Some(("shairport-sync", "AirPlay 2", "shairport-sync")),
        JobRecipe::AddMusicAssistant => None,
    }
}

fn append_service_to_manifest(path: &str, id: &str, name: &str, unit: &str) -> Result<(), String> {
    let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    let mut doc = text
        .parse::<toml_edit::DocumentMut>()
        .map_err(|e| e.to_string())?;
    if let Some(arr) = doc
        .entry("service")
        .or_insert(toml_edit::Item::ArrayOfTables(Default::default()))
        .as_array_of_tables_mut()
    {
        // Don't add it twice if a job is somehow re-run after already succeeding.
        if arr.iter().any(|t| t.get("id").and_then(|v| v.as_str()) == Some(id)) {
            return Ok(());
        }
        let mut t = toml_edit::Table::new();
        t["id"] = toml_edit::value(id);
        t["name"] = toml_edit::value(name);
        t["unit"] = toml_edit::value(unit);
        t["toggleable"] = toml_edit::value(true);
        arr.push(t);
    }
    std::fs::write(path, doc.to_string()).map_err(|e| e.to_string())
}

fn run_job(
    recipe: JobRecipe,
    params: HashMap<String, String>,
    manifest: &Manifest,
    manifest_path: &str,
    job: &SharedJob,
) -> Response {
    {
        let guard = job.lock().unwrap();
        if let Some(j) = guard.as_ref() {
            if j.running {
                return Response::Error {
                    message: "a job is already running".into(),
                };
            }
        }
    }

    let (script, allowed_env): (Option<&String>, &[&str]) = match recipe {
        // NAME/AIRPLAY_NAME/MA_PLAYER/BUILD: job scripts may take any of these
        // (install.sh's wrappers in pi/jobs/ use the room's remembered answers
        // and only honour BUILD) - an unused var in the env is harmless, so
        // allow the union rather than maintaining a separate list per script.
        JobRecipe::AddQobuz => (manifest.jobs.add_qobuz.as_ref(), &["BUILD", "NAME", "MA_PLAYER"][..]),
        JobRecipe::AddSpotify => (manifest.jobs.add_spotify.as_ref(), &["NAME", "BUILD"][..]),
        JobRecipe::AddAirplay2 => (manifest.jobs.add_airplay2.as_ref(), &["AIRPLAY_NAME"][..]),
        JobRecipe::AddMusicAssistant => (manifest.jobs.add_ma.as_ref(), &["MA_URL", "MA_TOKEN"][..]),
    };
    let Some(script) = script else {
        return Response::Error {
            message: format!("no script configured for {} in the manifest", recipe.label()),
        };
    };

    let env: Vec<(String, String)> = params
        .into_iter()
        .filter(|(k, _)| allowed_env.contains(&k.as_str()))
        .collect();

    let mut cmd = Command::new("bash");
    cmd.arg(script)
        .envs(env)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            return Response::Error {
                message: e.to_string(),
            }
        }
    };

    *job.lock().unwrap() = Some(JobState {
        lines: vec![],
        running: true,
        exit_ok: None,
    });

    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let job_out = job.clone();
    let job_err = job.clone();
    std::thread::spawn(move || pump(stdout, job_out));
    std::thread::spawn(move || pump(stderr, job_err));

    let job_wait = job.clone();
    let manifest_path = manifest_path.to_string();
    std::thread::spawn(move || {
        let status = child.wait();
        let ok = status.map(|s| s.success()).unwrap_or(false);
        if ok {
            if let Some((id, name, unit)) = recipe_service(recipe) {
                if let Err(e) = append_service_to_manifest(&manifest_path, id, name, unit) {
                    eprintln!("job succeeded but couldn't update manifest: {e}");
                }
            }
        }
        if let Some(j) = job_wait.lock().unwrap().as_mut() {
            j.running = false;
            j.exit_ok = Some(ok);
        }
    });

    Response::JobStarted {
        job_id: "current".into(),
    }
}

fn pump(reader: impl Read, job: SharedJob) {
    let reader = BufReader::new(reader);
    for line in reader.lines() {
        let Ok(line) = line else { break };
        if let Some(j) = job.lock().unwrap().as_mut() {
            j.lines.push(line);
        }
    }
}

fn job_log(since: usize, job: &SharedJob) -> Response {
    let guard = job.lock().unwrap();
    match guard.as_ref() {
        None => Response::JobLog {
            lines: vec![],
            next_offset: 0,
            running: false,
            exit_ok: None,
        },
        Some(j) => {
            let lines = j.lines.get(since..).unwrap_or(&[]).to_vec();
            Response::JobLog {
                next_offset: j.lines.len(),
                lines,
                running: j.running,
                exit_ok: j.exit_ok,
            }
        }
    }
}

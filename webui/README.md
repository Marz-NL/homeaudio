# playerui

The web control panel for a room: shows what's playing (real
title/artist/cover, not just which app), lets you switch each source on or
off, connect Music Assistant, and add a source from a button - all from a
page that shows every room at once. No JS framework, no login, LAN-trust
throughout. `install.sh room` sets it up; this is how it works inside.

## Why two binaries

`playerui` is what the LAN talks to, and it has **no elevated privilege at
all** - it reads status directly (systemctl queries, a couple of state
files) and forwards every privileged action to `player-guard-helper` over a
Unix socket. The helper runs as root and is the only thing that enforces
what's actually allowed: which units may be toggled, which config keys may be
written and how, which job recipes exist and what parameters they accept.
`playerui` never gets to decide any of that, only to ask - so a bug or a
deliberately malicious LAN request against the unprivileged, no-auth web
process can't turn into more than what the helper's own allowlists permit.

```
[browser, no auth] --HTTP--> [playerui, unprivileged] --Unix socket--> [player-guard-helper, root]
```

## Layout

- `protocol/` - the shared request/response types and wire framing (one JSON
  line per message) used by both binaries.
- `playerui/` - the web-facing half. `static/index.html` is embedded into the
  binary at compile time, so deployment is one file.
- `helper/` - `player-guard-helper`, root-owned, Unix-socket-only.
- `config/room.example.toml` - the manifest (`/etc/player-guard-services.toml`)
  a room's binaries and player-guard read: which sources exist and are
  toggleable, where Music Assistant's settings live, the job recipes behind
  "Add a source", the other rooms (for the whole-house page) and the volume
  settings. `install.sh room` writes it; a successful "Add a source" job
  appends its `[[service]]` entry itself (via `toml_edit`, keeping the rest of
  the file's formatting).
- `config/hub.example.toml` + `docker/` - the hub: the same page on any Docker
  host, listing every room and running nothing else (`install.sh hub` is
  coming; see the main README for the Docker steps).

## Run locally

```
cargo build
./target/debug/player-guard-helper config/room.example.toml /tmp/helper.sock
./target/debug/playerui config/room.example.toml 127.0.0.1:8189
```

Point both at the same manifest and socket path (edit `helper_socket` in a
copy of the manifest). On a dev machine (no root, no real pibuz/spotifyd/etc
units) the status/discovery endpoints work fully; anything that needs
`systemctl` to succeed returns a clean permission error instead of crashing.

## Notes

- No auth on any endpoint - deliberate, matches pibuz's own control API's
  trust model, but keep it on the LAN.
- The curated config editing covers one case so far (Music Assistant's three
  fields in `/etc/player-guard.env`). Extending it follows the same pattern:
  a `write_config` match arm per service in the helper.

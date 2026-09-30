# homeaudio

Turn Raspberry Pis with a good DAC into room players for **Qobuz Connect,
Spotify Connect, AirPlay 2 and Music Assistant** - one source at a time per
room, one volume, one web page for the whole house. Optionally bridge a
Denon/Marantz **HEOS** speaker into Qobuz Connect too.

- **Last one wins, politely.** Start playing from any app and it takes the
  room; the app that was playing is paused (not killed), so switching back
  continues where it was.
- **One volume.** All sources drive the DAC's hardware volume, so 30% is 30%
  whichever app you use. (DACs without volume control, like S/PDIF outputs,
  keep each app's own volume.)
- **A web page per room** (`http://<pi>.local:8189`) showing what plays, with
  switches per source and every room on one page. Optionally a hub container
  on a homelab with the same page.
- **No cloud, no accounts** beyond the ones your apps already use.

## Quick start: a room

You need a Raspberry Pi 4/5 (or 3B+) with a USB DAC or a DAC/S/PDIF HAT, and
a fresh SD card with **Raspberry Pi OS Lite (64-bit)**, Debian 13 "trixie".

```
sudo apt install -y git
sudo git clone https://github.com/Marz-NL/homeaudio /opt/homeaudio
cd /opt/homeaudio
sudo ./install.sh room
```

The installer finds your DAC and its volume control, asks which apps you
want (Qobuz, Spotify, AirPlay 2, Music Assistant) and a few names, and sets
everything up. A HAT that isn't enabled yet: it offers to enable it and asks
for a reboot - then run the same command again.

Afterwards:

- Open `http://<this pi>.local:8189`.
- Qobuz: pick the room once in the Qobuz app; it stays available from then on.
- Check everything: `sudo ./install.sh doctor`
- Add an app later: `sudo ./install.sh add spotify` (or use "Add a source" on the web page).
- Change answers: `sudo ./install.sh room --reconfigure`
- See what it would do first: `sudo ./install.sh room --dry-run`

Answers are kept in `/etc/homeaudio/install.conf`, so re-running (e.g. after
`git pull`) updates without asking again. Everything the installer did is in
`/var/log/homeaudio-install.log`.

### Music Assistant

Optional, and installed by you (see [music-assistant.io](https://music-assistant.io)).
Say yes to it during `install.sh room` (or `install.sh add ma` later), give
its address and a long-lived token (Settings > Profile), and the room shows
up in Music Assistant as a player.

## The hub (optional)

The same web page on any Docker host, listing every room - handy as one
bookmark for the house. `install.sh hub` is coming; for now:

```
cd webui
cp config/hub.example.toml config/hub.toml     # list your rooms
cd docker && docker compose up -d --build       # http://<host>:8189
```

## HEOS bridge (optional)

Makes a HEOS speaker a Qobuz Connect device, on a homelab or on a Pi.
`install.sh heos` (also without Docker) is coming; for now, with Docker:

```
cd heos-bridge
cp .env.example .env                            # HEOS speaker address etc.
docker compose up -d --build
```

Then log in to Qobuz once at `http://<host>:8689`. `http://<host>:8091`
shows what the speaker plays, whichever app started it.

## How it fits together

```
 phone apps ──► Qobuz Connect (pibuz) ─┐
            ──► Spotify Connect (spotifyd) ─┤
            ──► AirPlay 2 (shairport-sync) ─┼──► DAC ──► amplifier
 Music Assistant ──► sendspin ──────────────┘
                         │
          player-guard: who has the DAC, pauses the others, volume
                         │
          playerui (+ player-guard-helper) ◄── browser, :8189
          now-playing ──► playerui, optional Home Assistant webhook
```

| Directory | What |
|---|---|
| `install.sh`, `lib/` | the installer: `lib/room.sh`, `lib/sources/*`, `lib/doctor.sh` |
| `pi/bin/` | runs on each room: `player-guard`, `now-playing`, the apps' hooks |
| `pi/jobs/` | what playerui's "Add a source" runs |
| `webui/` | playerui, player-guard-helper, the hub container ([README](webui/README.md)) |
| `heos-bridge/` | qobuz-proxy with HEOS support + heos-guard |
| `patches/` | the spotifyd linear-volume patch used for the prebuilt binary |

## Licenses

MIT (see `LICENSE`). `heos-bridge/qobuz-proxy` is leolobato's MIT project
with HEOS changes; spotifyd (shipped prebuilt) is GPL-3.0. Details, and the
other projects the installer fetches, in [THIRD-PARTY.md](THIRD-PARTY.md).

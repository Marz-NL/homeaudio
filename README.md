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
  switches per source and every room on one page - rooms find each other on
  the network by themselves. Optionally a hub container
  on a homelab with the same page.
- **Bit-perfect, or one fixed rate.** Every track plays at its own rate,
  untouched. For a studio - a DAC into an audio interface locked to 44.1 or
  48 kHz - an optional sample-rate converter (CamillaDSP) switches live from
  the web page, without interrupting the music.
- **No cloud, no accounts** beyond the ones your apps already use.

> **Status: beta.** Runs daily in two rooms and a studio here, on Raspberry
> Pi OS (trixie, 64-bit) with an E30 USB DAC, a HiFiBerry DAC+ and a
> HiFiBerry Digi+ Pro (S/PDIF). Qobuz, AirPlay 2 and Music Assistant are
> tested the most; Spotify works but has seen less testing, the sample-rate
> converter is new. Bug reports welcome - `sudo ./install.sh doctor` output
> helps.

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
- Output rate: the Output card on the web page, or `sudo ./install.sh rate 44100`
  (see below).
- Change answers: `sudo ./install.sh room --reconfigure`
- See what it would do first: `sudo ./install.sh room --dry-run`
- Remove it all again: `sudo ./install.sh uninstall` (`--purge` also forgets
  the answers and the apps' logins)

Answers are kept in `/etc/homeaudio/install.conf`, so re-running (e.g. after
`git pull`) updates without asking again. Everything the installer did is in
`/var/log/homeaudio-install.log`.

### Music Assistant

Optional, and installed by you (see [music-assistant.io](https://music-assistant.io)).
The installer looks for it on the network and offers to connect the room; or
later, use "Set up" on the web page's Music Assistant card (or
`install.sh add ma`). You need a long-lived token from Music Assistant
(Settings > Profile). The room then shows up in Music Assistant as a player.

### Output rate (studio)

By default every source plays straight on the DAC at the music's own rate
(bit-perfect). If the DAC feeds something that runs at a fixed clock - an
audio interface's S/PDIF input while your DAW session is at 44.1 or 48 kHz -
answer yes to "Sample-rate converter" during `install.sh room`, or just pick
44.1 or 48 kHz on the web page's Output card later.

The sources then play into [CamillaDSP](https://github.com/HEnquist/camilladsp),
which feeds the DAC: at the track's own rate (Bit-perfect, passed through
untouched) or converted to the rate you picked (with 1 dB of headroom, since
resampling can overshoot near full scale). Switching between those is live:
the music keeps playing, no app loses its connection. Only moving a room onto
CamillaDSP the first time restarts the sources once.

```
sudo ./install.sh rate 48000     # native | 44100 | 48000, live
sudo ./install.sh rate direct    # back to sources straight on the DAC
```

## The hub (optional)

The same web page on any Docker host, listing every room - handy as one
bookmark for the house. `install.sh hub` is coming; for now:

```
cd webui
cp config/hub.example.toml config/hub.toml
cd docker && docker compose up -d --build       # http://<host>:8189
```

It finds the rooms by itself through the host's avahi-daemon (the container
talks to it over the mounted D-Bus socket, no host networking). A host
without avahi: remove that mount from `docker-compose.yml` and list the rooms
in `hub.toml`.

## HEOS bridge (optional)

Makes a HEOS speaker a Qobuz Connect device, on a homelab or on a Pi.

> **Tested with one speaker only: a Denon HEOS 5.** Other HEOS models (and
> Marantz/Denon amplifiers with HEOS built in) speak the same HEOS CLI
> protocol, so they may well work, but nobody has tried yet. If you do, an
> issue saying how it went - working or not - is very welcome.

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
            ──► AirPlay 2 (shairport-sync) ─┼──► [CamillaDSP] ──► DAC ──► amplifier
 Music Assistant ──► sendspin ──────────────┘    (optional: fixed rate)
                         │
          player-guard: who has the DAC, pauses the others, volume
                         │
          playerui (+ player-guard-helper) ◄── browser, :8189
          now-playing ──► playerui, optional Home Assistant webhook
```

| Directory | What |
|---|---|
| `install.sh`, `lib/` | the installer: `lib/room.sh`, `lib/sources/*`, `lib/output.sh` (output rate), `lib/doctor.sh` |
| `pi/bin/` | runs on each room: `player-guard`, `now-playing`, the apps' hooks |
| `pi/jobs/` | what playerui's "Add a source", Music Assistant and Output cards run |
| `webui/` | playerui, player-guard-helper, the hub container ([README](webui/README.md)) |
| `heos-bridge/` | qobuz-proxy with HEOS support + heos-guard |
| `patches/` | what the prebuilt binaries change upstream: spotifyd (linear volume), alsa_cdsp (stream restarts) |

## Security

The web page and its API have no login, by design - like the apps' own
Connect protocols, they trust the local network. Keep port 8189 off the
internet. Privileged actions go through a small root helper that only allows
a fixed list of things (see [webui/README.md](webui/README.md)).

## Credits

homeaudio mostly glues together other people's excellent work:
[pibuz](https://github.com/PhilipVinc/pibuz) (Qobuz Connect),
[spotifyd](https://github.com/Spotifyd/spotifyd),
[shairport-sync](https://github.com/mikebrady/shairport-sync) and
[nqptp](https://github.com/mikebrady/nqptp) (AirPlay 2),
[sendspin](https://github.com/Sendspin/sendspin-python-cli) and
[Music Assistant](https://github.com/music-assistant/server),
[CamillaDSP](https://github.com/HEnquist/camilladsp) and
[alsa_cdsp](https://github.com/scripple/alsa_cdsp), and
[qobuz-proxy](https://github.com/leolobato/qobuz-proxy) for the HEOS bridge.

## Licenses

MIT (see `LICENSE`). `heos-bridge/qobuz-proxy` is leolobato's MIT project
with HEOS changes; spotifyd (shipped prebuilt) and CamillaDSP (downloaded from
its project) are GPL-3.0. Details, and the
other projects the installer fetches, in [THIRD-PARTY.md](THIRD-PARTY.md).

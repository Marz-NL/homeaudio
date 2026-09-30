# Installer plan

One script, `install.sh`, run once per machine, choosing one or more roles:

```
sudo ./install.sh room            # a Pi with a DAC
./install.sh hub                  # a Docker host: playerui-hub (overview of all rooms)
./install.sh heos                 # HEOS bridge (qobuz-proxy + heos-guard) - on the hub or on a Pi
./install.sh room heos            # combined
./install.sh add <source>         # add a source later (also what playerui's "Add a source" runs)
./install.sh rate <rate>          # output: native | 44100 | 48000 (live, CamillaDSP) | direct
./install.sh doctor               # check everything, explain what's wrong
```

## Decisions

- Every source is optional and equal: Music Assistant, Qobuz (pibuz), Spotify
  (spotifyd), AirPlay 2 (shairport-sync). A room may run e.g. only Spotify +
  Qobuz + AirPlay. Music Assistant itself is installed by the user; the
  installer only connects a room to it (sendspin, URL, token, player id lookup).
- spotifyd ships prebuilt (aarch64, linear-volume patch) from GitHub Releases.
  spotifyd is GPL-3.0: the release carries the patch and the exact upstream
  version and build command. BUILD=1 builds from source instead.
- playerui and player-guard-helper ship prebuilt from GitHub Releases too.
  shairport-sync + nqptp are built from source (no upstream aarch64 builds).
- Answers are stored in /etc/homeaudio/install.conf: a re-run asks nothing and
  updates. Idempotent; --dry-run shows the plan without changing anything.
- Secrets only in /etc/player-guard.env (0640 root:audioguard), never in the repo.

## What a room needs

| Part | Installed | Asked / detected |
|---|---|---|
| Base | audio user in `audio` + `audioguard`, /run/player-guard, inotify-tools, curl, jq | room name, audio user |
| DAC | - | card (/proc/asound/cards), mixer control (amixer scontrols), sample format |
| player-guard | guard, hooks, unit | - |
| playerui + helper | binaries, units, /etc/player-guard-services.toml | other rooms' URLs (default: *.local) |
| now-playing | script, unit | optional Home Assistant webhook |
| Volume | [volume] in the manifest | mode shared / per_source |
| Music Assistant | sendspin + unit (--hardware-volume true), ma-* helpers | MA URL + token; player id looked up via the MA API |
| Qobuz | pibuz release + settings (hw, device, name, hook, linear) | - (one cast from the phone afterwards) |
| Spotify | spotifyd + D-Bus policy + conf following [volume] | - |
| AirPlay 2 | nqptp + shairport-sync (source build), conf with mixer + hooks | - |
| Output rate (optional) | CamillaDSP (its release binary), alsa_cdsp plugin (our release, or built), ALSA device `homeaudio`, /usr/local/lib/homeaudio/cdsp-config | sample-rate converter y/n (default n); rate switched live later |

## What a hub / HEOS host needs

| Part | Asked |
|---|---|
| playerui-hub | rooms (default: found via *.local) |
| heos (optional) | HEOS IP, MA URL/token (optional), HA webhook (optional); Qobuz login once in qobuz-proxy's web page (:8689) |

## Phases

1. Specification (this file), checked against the running Pis.
2. Repo restructure: `install.sh` + `lib/` modules; `room` role first, all sources optional
   (player-guard: no MA assumptions, sendspin recognised by name).
3. CI: GitHub Actions builds aarch64 playerui, player-guard-helper, spotifyd (patched) into a release.
4. Test on a clean Pi (fresh SD card), then `add` per source.
5. `hub` and `heos` roles, tested on a homelab and on a Pi.
6. README: architecture, quick start per role, credits and licenses.
7. Publish: one fresh commit after a final private-data scan.

## DACs without a mixer

S/PDIF outputs (e.g. HiFiBerry Digi) usually have no hardware volume control.
When no playback-volume control is found, the manifest's [volume] section gets
no mixer: player-guard leaves the volume alone and every source keeps its own
software volume (typical for S/PDIF into an amplifier with its own knob).

## HEOS without Docker

The `heos` role installs qobuz-proxy and heos-guard into a Python venv
(/opt/homeaudio/venv) with two systemd units - fits a simple headless Pi. On a
host with Docker the compose variant stays available; --no-docker forces the
venv variant.

## Output rate

Rooms default to `direct`: every source opens the DAC itself, bit-perfect. A
fixed rate used to mean an ALSA plug device per source - every switch then had
to reopen every source, and pibuz only rereads ALSA when restarted (losing its
Qobuz Connect session). Instead the conversion now sits in one place:
sources play into the ALSA plugin alsa_cdsp, which starts CamillaDSP per
stream at that stream's own rate and format. CamillaDSP resamples once, to
the chosen rate, or passes through for bit-perfect. A switch rewrites its
config and sends SIGHUP: live, ~0.1 s, sources untouched. player-guard and
now-playing look through camilladsp to its parent process to see the source.

## Test hardware

A spare Pi with an S/PDIF output and a fresh SD card (Raspberry Pi OS Lite
64-bit, Trixie): the clean-install test for phase 4, and the no-mixer case.

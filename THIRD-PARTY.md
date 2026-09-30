# Third-party software

None of this exists without the open-source projects below - thank you.

homeaudio is MIT (see `LICENSE`), except where noted below.

## Included in this repository

| What | Where | License |
|---|---|---|
| [qobuz-proxy](https://github.com/leolobato/qobuz-proxy) by leolobato, with HEOS changes | `heos-bridge/qobuz-proxy/` | MIT - its own `LICENSE`; changes listed in its `FORK.md` |

## Shipped in the releases (prebuilt binaries)

| What | License |
|---|---|
| `playerui`, `player-guard-helper` (this project) and the Rust crates linked into them | MIT; each crate's license text is in the release's `THIRD-PARTY-LICENSES.txt` |
| [spotifyd](https://github.com/Spotifyd/spotifyd) v0.4.2 with `patches/spotifyd-linear-volume.patch` | GPL-3.0 - the source is that upstream tag plus the patch, both linked from the release (`SPOTIFYD-SOURCE.md`) |

## Installed from their own sources by `install.sh`

Not part of this repository; the installer downloads them from their
projects when you choose the source that needs them.

| What | Used for | License |
|---|---|---|
| [pibuz](https://github.com/PhilipVinc/pibuz) (release download) | Qobuz Connect | MIT |
| [shairport-sync](https://github.com/mikebrady/shairport-sync) by Mike Brady, building on James Laird's original shairport (built from source) | AirPlay 2 | MIT-style, per file (see its `LICENSES`) |
| [nqptp](https://github.com/mikebrady/nqptp) by Mike Brady (built from source) | AirPlay 2 clock sync | GPL-2.0 |
| [sendspin](https://github.com/Sendspin/sendspin-python-cli) (via uv) | Music Assistant player | Apache-2.0 |
| [uv](https://github.com/astral-sh/uv) | installs sendspin | Apache-2.0 / MIT |

## Used, not installed

[Music Assistant](https://github.com/music-assistant/server) (Apache-2.0):
optional, you run it yourself; a room connects to it.

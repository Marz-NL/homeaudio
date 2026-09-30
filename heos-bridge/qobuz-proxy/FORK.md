# About this copy of qobuz-proxy

This directory is [qobuz-proxy](https://github.com/leolobato/qobuz-proxy) by
leolobato (MIT, see `LICENSE` - that notice applies to this directory), based
on upstream **1.7.6** (commit `6762817`), with changes for Denon/Marantz
**HEOS** speakers. HEOS has no real UPnP/DLNA transport and no seek command,
so it is driven over its own CLI protocol (port 1255).

Only tested with a **Denon HEOS 5**; other HEOS devices use the same CLI
protocol but are untested.

## Changes compared with upstream 1.7.6

| File | Change |
|---|---|
| `backends/dlna/heos_client.py` | new: HEOS CLI client (play_stream, play state, volume, position estimate, seek by reloading the stream from an offset) |
| `backends/dlna/flac_seek.py` | new: FLAC header/SEEKTABLE parsing, so the audio proxy can start a stream frame-aligned at any position |
| `backends/dlna/proxy_server.py` | `seek_ms`/`duration_ms` on a track URL: serve the stream from that position (FLAC header + frame-aligned offset) |
| `backends/dlna/backend.py` | use the HEOS client for HEOS devices; on a handoff mid-track start the stream at that position directly instead of playing from 0 and reloading; log a seek that can't move the audio |
| `backends/types.py`, `backends/base.py` | `BackendTrackMetadata.start_position_ms` and `AudioBackend.started_at_ms`, for the handoff start |
| `playback/player.py` | pass the start position to the backend and skip the extra seek when it already started there; `yield_to_peer()` |
| `playback/command_handler.py` | when another Qobuz Connect device takes over: pause and report PAUSED at the real position (`yield_to_peer`) instead of STOPPED at 0 - so the next device continues where this one was, and switching back resumes |
| `tests/...` | tests for the handoff start; two deactivation tests now expect PAUSED |
| `README.md` | a pointer to this file |

These changes are under the same MIT license. Anything generally useful here
may be offered upstream as a pull request.

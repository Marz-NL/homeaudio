"""
heos-guard - unified "who's playing" visibility for a HEOS speaker.

Unlike the Pi rooms' player-guard, this does not arbitrate device access -
HEOS's own firmware already enforces "last source to start playback wins"
for a single zone (that's why Spotify Connect, the HEOS app's own playback,
and a play_stream push from qobuz-proxy or Music Assistant each cleanly take
over the zone already). What's missing is visibility: one place that shows
which of Qobuz/Spotify/MASS/HEOS-native is actually active right now,
mirroring what player-guard-helper's status view gives the Pi rooms.

Source resolution, in order:
1. HEOS itself isn't playing -> "Idle".
2. HEOS's own sid (source id) resolves to a real native source name via
   get_music_sources (Spotify, TuneIn, Amazon Music, "Local Music" for
   Music Assistant, etc.) -> that name. Checked before qobuz-proxy's own
   self-report: qobuz-proxy can't reliably tell when another controller has
   taken the speaker over from it (that check was removed - see backend.py's
   can_apply_remote_state - since it caused false lockouts on ordinary
   skip/search/seek), so its own "playing" status can go stale and keep
   claiming ownership long after HEOS has actually moved on to something
   else. HEOS's own reported sid is ground truth in a way qobuz-proxy's
   self-belief no longer is.
3. Otherwise, qobuz-proxy's own /api/status says it's actively playing this
   speaker -> "Qobuz (bridge)". This only fires when HEOS's own sid *didn't*
   resolve to a real name, which is the normal case for our bridge's own
   playback: HEOS has no field distinguishing one url-stream pusher from
   another (our bridge and Music Assistant both use the same generic
   browse/play_stream call), so confirmation has to come from the pusher
   that knows it's the one currently pushing.
4. Otherwise it's a url-stream from something that isn't qobuz-proxy and
   isn't a resolvable native source - labeled "External stream (Music
   Assistant or other)" rather than guessing further.
"""

import asyncio
import json
import logging
import os
import time
from collections import deque
from pathlib import Path
from typing import Optional

import aiohttp
from aiohttp import web

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s")
logger = logging.getLogger("heos-guard")

HEOS_IP = os.environ.get("HEOS_IP", "")
HEOS_PORT = 1255
QOBUZ_PROXY_STATUS_URL = os.environ.get(
    "QOBUZ_PROXY_STATUS_URL", "http://qobuz-proxy:8689/api/status"
)
MASS_API_URL = os.environ.get("MASS_API_URL", "")
MASS_API_TOKEN = os.environ.get("MASS_API_TOKEN", "")
# Same push pattern as the Pi rooms' add-now-playing.sh -> Home Assistant
# webhook -> input_text helpers. Optional: unset means "don't push".
HA_WEBHOOK_URL = os.environ.get("HA_WEBHOOK_URL", "")
POLL_INTERVAL_SECONDS = 3.0
STATIC_DIR = Path(__file__).parent / "static"
LOG_MAX_ENTRIES = 50


class HeosConnection:
    """Persistent telnet connection to the HEOS CLI, one command at a time."""

    def __init__(self, ip: str):
        self._ip = ip
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._lock = asyncio.Lock()
        self._pid: Optional[str] = None
        self.sources_by_id: dict[str, str] = {}

    async def _ensure_open(self) -> None:
        if self._writer is None or self._writer.is_closing():
            self._reader, self._writer = await asyncio.open_connection(self._ip, HEOS_PORT)

    async def command(self, path: str) -> dict:
        async with self._lock:
            await self._ensure_open()
            assert self._reader and self._writer
            self._writer.write(f"heos://{path}\r\n".encode())
            await self._writer.drain()
            # HEOS pretty-prints some responses with real embedded newlines
            # and only \r\n-terminates the whole message at the very end -
            # readline() stops at the first bare \n and truncates those.
            raw = await asyncio.wait_for(self._reader.readuntil(b"\r\n"), timeout=5.0)
            if not raw:
                raise ConnectionError("HEOS closed the connection")
            return json.loads(raw.decode())

    async def connect_and_prime(self) -> None:
        """Get our player id and cache the sid -> source name table."""
        players = (await self.command("player/get_players")).get("payload") or []
        if not players:
            raise RuntimeError(f"No HEOS players found at {self._ip}")
        self._pid = str(players[0]["pid"])
        logger.info(f"Using HEOS player pid={self._pid}")

        sources = (await self.command("browse/get_music_sources")).get("payload") or []
        self.sources_by_id = {str(s["sid"]): s.get("name", "") for s in sources if "sid" in s}
        logger.info(f"Cached {len(self.sources_by_id)} HEOS music source names")

    async def poll(self) -> dict:
        assert self._pid
        state = await self.command(f"player/get_play_state?pid={self._pid}")
        now_playing = await self.command(f"player/get_now_playing_media?pid={self._pid}")
        volume = await self.command(f"player/get_volume?pid={self._pid}")
        return {
            "play_state": _parse_message(state.get("heos", {}).get("message", "")).get("state"),
            "now_playing": now_playing.get("payload") or {},
            "volume": _parse_message(volume.get("heos", {}).get("message", "")).get("level"),
        }


def _parse_message(message: str) -> dict:
    return dict(kv.split("=", 1) for kv in message.split("&") if "=" in kv)


async def _qobuz_proxy_status(session: aiohttp.ClientSession) -> dict:
    """Query qobuz-proxy's own /api/status for both connection health and
    (when it's the active source) real track metadata.

    HEOS's own get_now_playing_media only ever reports generic "Url Stream"
    text for anything pushed via play_stream, since it never sees real
    ID3/FLAC tags - qobuz-proxy already fetched the real title/artist/album
    (and cover art) from Qobuz's own API to play the track in the first
    place, so this is the actual source of truth whenever it's playing.

    "connected" here means the driver itself is up and talking to HEOS
    (backend status isn't "disconnected"), independent of whether it happens
    to be actively playing right now - that distinction is what "offline"
    is supposed to mean: speaker not found vs. driver not connected.
    """
    try:
        async with session.get(QOBUZ_PROXY_STATUS_URL, timeout=aiohttp.ClientTimeout(total=3)) as resp:
            if resp.status != 200:
                return {"connected": False, "detail": f"HTTP {resp.status}", "now_playing": None}
            data = await resp.json()
    except Exception as e:
        return {"connected": False, "detail": "unreachable", "now_playing": None}

    speakers = data.get("speakers", [])
    if not speakers:
        return {"connected": False, "detail": "no speaker configured", "now_playing": None}
    speaker = speakers[0]
    if speaker.get("status") == "disconnected":
        return {"connected": False, "detail": "driver not connected to HEOS", "now_playing": None}
    now_playing = speaker.get("now_playing") if speaker.get("status") == "playing" else None
    return {"connected": True, "detail": speaker.get("status", ""), "now_playing": now_playing}


async def _mass_now_playing(session: aiohttp.ClientSession, heos_player_id: str) -> Optional[dict]:
    """Real title/artist/album/art for the HEOS player from Music Assistant's
    own REST API, when MASS confirms it's actively playing that player.

    HEOS's own get_now_playing_media only reports generic "Url Stream" text
    for MASS's pushes (same limitation as qobuz-proxy's pushes - see the
    module docstring), but MASS's players/all response already carries the
    real current_media inline, keyed by the exact same player id HEOS itself
    uses (confirmed: MASS's player_id for this speaker equals HEOS's own pid).
    """
    if not (MASS_API_URL and MASS_API_TOKEN):
        return None
    try:
        async with session.post(
            f"{MASS_API_URL}/api",
            headers={"Authorization": f"Bearer {MASS_API_TOKEN}"},
            json={"command": "players/all", "args": {}},
            timeout=aiohttp.ClientTimeout(total=3),
        ) as resp:
            if resp.status != 200:
                return None
            data = await resp.json()
    except Exception:
        return None

    players = data.get("result", data) if isinstance(data, dict) else data
    for player in players or []:
        if player.get("player_id") != heos_player_id:
            continue
        if player.get("playback_state") != "playing":
            return None
        media = player.get("current_media")
        if not media:
            return None
        return {
            "title": media.get("title"),
            "artist": media.get("artist"),
            "album": media.get("album"),
            "album_art_url": media.get("image_url"),
        }
    return None


def _resolve_source(play_state: Optional[str], sid: Optional[str], qobuz_playing: bool, sources: dict) -> str:
    if play_state != "play":
        return "Idle"
    if sid and sid in sources and sources[sid]:
        return sources[sid]
    if qobuz_playing:
        return "Qobuz (bridge)"
    return "External stream (Music Assistant or other)"


async def _push_to_home_assistant(
    session: aiohttp.ClientSession, source: str, song: Optional[str], artist: Optional[str], cover: Optional[str]
) -> None:
    """Push current state to Home Assistant's webhook, same pattern as the Pi
    rooms' add-now-playing.sh -> input_text helpers. Optional: no-op if
    HA_WEBHOOK_URL isn't set.
    """
    if not HA_WEBHOOK_URL:
        return
    try:
        await session.post(
            HA_WEBHOOK_URL,
            json={"source": source or "", "title": song or "", "artist": artist or "", "cover": cover or ""},
            timeout=aiohttp.ClientTimeout(total=5),
        )
    except Exception as e:
        logger.warning(f"Failed to push to Home Assistant webhook: {e}")


class GuardState:
    def __init__(self) -> None:
        self.last: dict = {"status": "starting"}
        self.updated_at: float = 0.0
        self.log: deque = deque(maxlen=LOG_MAX_ENTRIES)
        self.last_source: Optional[str] = None

    def log_event(self, message: str) -> None:
        self.log.append({"ts": time.time(), "message": message})


async def poll_loop(app: web.Application) -> None:
    state: GuardState = app["state"]
    heos: HeosConnection = app["heos"]
    session: aiohttp.ClientSession = app["http"]

    while True:
        heos_connection = {"connected": True, "detail": "ok"}
        try:
            snapshot = await heos.poll()
        except Exception as e:
            logger.warning(f"HEOS poll failed: {e}")
            heos_connection = {"connected": False, "detail": "speaker not found"}
            state.last = {
                "status": "error",
                "connections": {"heos": heos_connection, "qobuz_proxy": None},
            }
            if state.last_source is not None:
                state.log_event(f"HEOS unreachable (was: {state.last_source})")
                state.last_source = None
            await asyncio.sleep(POLL_INTERVAL_SECONDS)
            continue

        qobuz_status = await _qobuz_proxy_status(session)
        qobuz_now_playing = qobuz_status["now_playing"]
        mass_now_playing = (
            None if qobuz_now_playing is not None else await _mass_now_playing(session, heos._pid)
        )
        now_playing = snapshot["now_playing"]
        source = _resolve_source(
            snapshot["play_state"],
            str(now_playing.get("sid", "")),
            qobuz_now_playing is not None,
            heos.sources_by_id,
        )

        if source != state.last_source:
            if state.last_source is not None:
                state.log_event(f"{state.last_source} -> {source}")
            state.last_source = source

        if qobuz_now_playing is not None:
            song = qobuz_now_playing.get("title")
            artist = qobuz_now_playing.get("artist")
            album = qobuz_now_playing.get("album")
            album_art_url = qobuz_now_playing.get("album_art_url")
        elif mass_now_playing is not None:
            song = mass_now_playing.get("title")
            artist = mass_now_playing.get("artist")
            album = mass_now_playing.get("album")
            album_art_url = mass_now_playing.get("album_art_url")
        else:
            song = now_playing.get("song") or now_playing.get("station")
            artist = now_playing.get("artist")
            album = now_playing.get("album")
            album_art_url = None

        state.last = {
            "status": "ok",
            "play_state": snapshot["play_state"],
            "source": source,
            "song": song,
            "artist": artist,
            "album": album,
            "album_art_url": album_art_url,
            "volume": snapshot["volume"],
            "connections": {"heos": heos_connection, "qobuz_proxy": qobuz_status},
        }
        state.updated_at = time.time()
        await _push_to_home_assistant(session, source, song, artist, album_art_url)
        await asyncio.sleep(POLL_INTERVAL_SECONDS)


async def handle_status(request: web.Request) -> web.Response:
    state: GuardState = request.app["state"]
    return web.json_response({**state.last, "updated_at": state.updated_at, "log": list(state.log)[::-1]})


async def on_startup(app: web.Application) -> None:
    app["http"] = aiohttp.ClientSession()
    heos = HeosConnection(HEOS_IP)
    for attempt in range(10):
        try:
            await heos.connect_and_prime()
            break
        except Exception as e:
            logger.warning(f"HEOS not ready yet ({e}), retrying...")
            await asyncio.sleep(3)
    app["heos"] = heos
    app["poll_task"] = asyncio.create_task(poll_loop(app))


async def on_cleanup(app: web.Application) -> None:
    app["poll_task"].cancel()
    await app["http"].close()


async def handle_index(request: web.Request) -> web.FileResponse:
    return web.FileResponse(STATIC_DIR / "index.html")


def build_app() -> web.Application:
    app = web.Application()
    app["state"] = GuardState()
    app.router.add_get("/api/status", handle_status)
    # aiohttp's static handler doesn't auto-serve index.html for the bare
    # "/" path (it 403s instead), so serve it explicitly.
    app.router.add_get("/", handle_index)
    app.router.add_static("/", STATIC_DIR, show_index=False)
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    return app


if __name__ == "__main__":
    if not HEOS_IP:
        raise SystemExit("heos-guard: set HEOS_IP (see .env.example)")
    web.run_app(build_app(), host="0.0.0.0", port=8091)

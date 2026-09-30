"""
HEOS native CLI client.

Denon/Marantz HEOS speakers do not implement UPnP AVTransport and never
answer SSDP discovery at all - they use their own proprietary line-based
JSON-over-telnet protocol on a fixed port (1255), documented in Denon's own
"HEOS CLI Protocol Specification". This client speaks that protocol directly
and exposes the same public interface as DLNAClient, so DLNABackend can drive
a HEOS speaker exactly like it drives a real DLNA renderer, with no changes
to any of the surrounding playback/proxy/gapless logic.

The key command is "browse/play_stream" (spec section 4.4.10): given a pid
and a plain HTTP URL, the device fetches and plays it directly - which is
exactly the audio-proxy URL DLNABackend already builds for every track.
"""

import asyncio
import json
import logging
import time
from typing import Optional

from .client import DLNADeviceInfo, SoapResult

logger = logging.getLogger(__name__)

HEOS_PORT = 1255

_COMMAND_TIMEOUT_SECONDS = 5.0


class HeosClientError(Exception):
    """HEOS CLI client error."""


def _parse_message(message: str) -> dict:
    """Parse a HEOS response 'message' field ('pid=1&state=play') into a dict."""
    return dict(kv.split("=", 1) for kv in message.split("&") if "=" in kv)


class HeosClient:
    """Minimal client for HEOS's native CLI protocol (telnet, port 1255)."""

    def __init__(self, ip: str, port: int = HEOS_PORT, description_url: Optional[str] = None):
        self._ip = ip
        self.device_info: Optional[DLNADeviceInfo] = None
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._pid: Optional[str] = None
        self._lock = asyncio.Lock()

        # HEOS has no "what URL is loaded" query the way UPnP AVTransport
        # does (get_now_playing_media returns song/artist metadata, not a raw
        # URL) - so we echo back what we last told it to play. DLNABackend's
        # ownership checks compare this against the URL it expects, which is
        # exactly the behavior we want after a successful play_stream.
        self._last_uri: Optional[str] = None

        # HEOS also has no position/seek query or command, so position is
        # estimated locally from wall-clock time since the last play/pause.
        self._playing_since: float = 0.0
        self._position_at_marker_ms: int = 0

    # -- connection -----------------------------------------------------

    async def connect(self) -> DLNADeviceInfo:
        await self._open()
        response = await self._command("player/get_players")
        payload = response.get("payload") or []
        if not payload:
            raise HeosClientError(f"No HEOS players reported by {self._ip}")
        player = payload[0]
        self._pid = str(player["pid"])
        self.device_info = DLNADeviceInfo(
            friendly_name=player.get("name") or f"HEOS ({self._ip})",
            manufacturer="Denon",
            model_name=player.get("model", "HEOS"),
            udn=f"heos:{self._pid}",
        )
        logger.info(
            f"Connected to HEOS player '{self.device_info.friendly_name}' (pid={self._pid})"
        )
        return self.device_info

    async def _open(self) -> None:
        self._reader, self._writer = await asyncio.open_connection(self._ip, HEOS_PORT)

    async def reset_session(self) -> None:
        """Drop the telnet connection; the next command reopens it."""
        await self.disconnect()

    async def disconnect(self) -> None:
        if self._writer:
            self._writer.close()
            try:
                await self._writer.wait_closed()
            except Exception:
                pass
        self._reader = None
        self._writer = None

    async def _command(self, path: str) -> dict:
        """Send one HEOS CLI command and return its parsed JSON response."""
        async with self._lock:
            if self._writer is None or self._writer.is_closing():
                await self._open()
            assert self._reader and self._writer
            self._writer.write(f"heos://{path}\r\n".encode())
            await self._writer.drain()
            # HEOS pretty-prints some responses (e.g. get_players) with real
            # embedded newlines and only terminates the whole message with
            # \r\n at the very end - a plain readline() (which stops at the
            # first bare \n) truncates those mid-message. readuntil(b"\r\n")
            # waits for the real terminator instead.
            raw = await asyncio.wait_for(
                self._reader.readuntil(b"\r\n"), timeout=_COMMAND_TIMEOUT_SECONDS
            )
            if not raw:
                raise HeosClientError("HEOS closed the connection")
            data = json.loads(raw.decode())
            heos = data.get("heos", {})
            if heos.get("result") != "success":
                logger.warning(f"HEOS command failed: {path} -> {heos}")
            return data

    # -- transport --------------------------------------------------------

    async def set_av_transport_uri(self, url: str, metadata: str = "") -> bool:
        try:
            # Per spec 4.4.10: url must be the last param and is taken raw,
            # not percent-encoded - percent-encoding it makes HEOS silently
            # fail to fetch anything while still ACKing the command itself.
            data = await self._command(f"browse/play_stream?pid={self._pid}&url={url}")
        except Exception as e:
            logger.warning(f"HEOS play_stream failed: {e}")
            return False
        ok = data.get("heos", {}).get("result") == "success"
        if ok:
            self._last_uri = url
            self._position_at_marker_ms = 0
            self._playing_since = time.monotonic()
        return ok

    async def play(self, speed: str = "1") -> bool:
        ok = await self._set_play_state("play")
        if ok:
            self._playing_since = time.monotonic()
        return ok

    async def pause(self) -> bool:
        ok = await self._set_play_state("pause")
        if ok:
            self._position_at_marker_ms = self._estimate_position_ms()
            self._playing_since = 0.0
        return ok

    async def stop(self) -> bool:
        ok = await self._set_play_state("stop")
        if ok:
            self._last_uri = None
            self._playing_since = 0.0
            self._position_at_marker_ms = 0
        return ok

    async def _set_play_state(self, state: str) -> bool:
        try:
            data = await self._command(f"player/set_play_state?pid={self._pid}&state={state}")
        except Exception as e:
            logger.warning(f"HEOS set_play_state({state}) failed: {e}")
            return False
        return data.get("heos", {}).get("result") == "success"

    async def seek(self, position_ms: int) -> bool:
        """Fallback only, used when seek_via_reload() has nothing to work
        with (no duration known yet). Just updates our own position estimate
        so the UI doesn't show a stale value; playback position on the
        device itself does not move. Prefer seek_via_reload() - see there for
        why HEOS needs this workaround at all.
        """
        self._position_at_marker_ms = position_ms
        self._playing_since = time.monotonic()
        return True

    def note_started_at(self, url: str, position_ms: int) -> None:
        """play_stream was given a seek_ms URL: track the original url (as
        seek_via_reload does) and start the position estimate there."""
        self._last_uri = url
        self._position_at_marker_ms = position_ms
        self._playing_since = time.monotonic()

    async def seek_via_reload(self, url: str, position_ms: int, duration_ms: int) -> bool:
        """Approximate a real seek: HEOS's CLI protocol has no seek command at
        all (confirmed against Denon's own HEOS CLI Protocol Specification -
        no such command exists), so the only way to move playback position is
        to have it re-fetch the track from a byte offset via play_stream.

        The offset is computed proportionally against the file's real size
        (qobuz_proxy's own audio-proxy handles the byte-offset Range request
        via its seek_ms/duration_ms query params - see proxy_server.py). This
        is not frame-accurate for compressed formats, so playback may glitch
        briefly right at the seek point while the decoder resyncs, but lands
        close enough in practice for CD-quality FLAC/MP3.
        """
        seek_url = f"{url}{'&' if '?' in url else '?'}seek_ms={position_ms}&duration_ms={duration_ms}"
        try:
            data = await self._command(
                f"browse/play_stream?pid={self._pid}&url={seek_url}"
            )
        except Exception as e:
            logger.warning(f"HEOS seek (play_stream reload) failed: {e}")
            return False
        ok = data.get("heos", {}).get("result") == "success"
        if ok:
            # play_stream alone only loads the new stream - HEOS stays
            # paused/stopped until a separate set_play_state=play, exactly
            # like a normal track load's play_stream+play pair.
            ok = await self._set_play_state("play")
        if ok:
            # Keep tracking the ORIGINAL (un-seeked) url, not seek_url, so
            # get_media_info()'s echo stays consistent with what backend.py
            # expects the "current" proxy url to be.
            self._last_uri = url
            self._position_at_marker_ms = position_ms
            self._playing_since = time.monotonic()
        return ok

    async def get_transport_info(self) -> Optional[str]:
        try:
            data = await self._command(f"player/get_play_state?pid={self._pid}")
        except Exception:
            return None
        state = _parse_message(data.get("heos", {}).get("message", "")).get("state")
        return {"play": "PLAYING", "pause": "PAUSED_PLAYBACK", "stop": "STOPPED"}.get(state)

    async def get_position_info(self) -> Optional[int]:
        return self._estimate_position_ms()

    def _estimate_position_ms(self) -> int:
        if not self._playing_since:
            return self._position_at_marker_ms
        elapsed_ms = int((time.monotonic() - self._playing_since) * 1000)
        return self._position_at_marker_ms + elapsed_ms

    async def get_track_uri(self) -> Optional[str]:
        return self._last_uri

    async def get_media_info(self) -> Optional[str]:
        return self._last_uri

    async def set_next_av_transport_uri(self, url: str, metadata: str = "") -> SoapResult:
        """No gapless support over the HEOS CLI.

        Reports a permanent failure (rather than a transient one) so
        DLNABackend disables gapless after the first attempt instead of
        retrying forever.
        """
        return SoapResult(
            success=False, error_code=401, error_description="Not supported by HEOS CLI"
        )

    # -- volume -------------------------------------------------------------

    async def get_volume(self) -> Optional[int]:
        try:
            data = await self._command(f"player/get_volume?pid={self._pid}")
        except Exception:
            return None
        level = _parse_message(data.get("heos", {}).get("message", "")).get("level")
        return int(level) if level is not None else None

    async def set_volume(self, volume: int) -> bool:
        try:
            data = await self._command(f"player/set_volume?pid={self._pid}&level={volume}")
        except Exception:
            return False
        return data.get("heos", {}).get("result") == "success"

    # -- capabilities ---------------------------------------------------

    async def get_protocol_info(self) -> Optional[str]:
        """No UPnP ConnectionManager on HEOS - skip capability discovery.

        DLNABackend falls back to a generic FLAC/MP3 protocol info string
        when this returns None, which is all play_stream needs anyway.
        """
        return None

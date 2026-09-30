"""
Audio Proxy Server.

HTTP server that proxies audio streams from Qobuz CDN to DLNA devices,
handling URL expiration transparently.
"""

import asyncio
import logging
import socket
import time
import traceback
from dataclasses import dataclass, field
from typing import Callable, Dict, Optional

from aiohttp import web, ClientError, ClientSession, ClientTimeout

from .flac_seek import FlacSeekInfo, find_next_frame_sync, find_seek_byte_offset, parse_flac_header
from .url_provider import StreamingURLProvider

logger = logging.getLogger(__name__)

# URL refresh settings
DEFAULT_URL_MAX_AGE_SECONDS = 240  # Refresh before 5-minute TTL
STREAM_CHUNK_SIZE = 64 * 1024  # 64KB chunks
REQUEST_TIMEOUT_SECONDS = 30
# Per-read timeout: fail fast when the CDN stalls mid-stream instead of hanging
# forever (the overall stream has no total timeout).
READ_TIMEOUT_SECONDS = 30
# Mid-stream reconnect settings: how many times to reconnect (with a Range resume)
# before giving up, and how long to back off between attempts.
MAX_UPSTREAM_RETRIES = 3
UPSTREAM_RETRY_DELAY_SECONDS = 0.5


def _parse_range_start(range_header: str) -> int:
    """Extract the start byte from a Range header ("bytes=X-...")."""
    try:
        return int(range_header.split("=", 1)[1].split("-", 1)[0] or 0)
    except (IndexError, ValueError):
        return 0


@dataclass
class RegisteredTrack:
    """A track registered with the proxy server."""

    track_id: str
    qobuz_url: str
    content_type: str
    url_fetched_at: float = field(default_factory=time.time)
    # Cached once per track on first seek (HEOS seek-via-reload only) - see
    # flac_seek.py for why this is needed at all.
    flac_seek_info: Optional[FlacSeekInfo] = None

    def is_url_expired(self, max_age: float = DEFAULT_URL_MAX_AGE_SECONDS) -> bool:
        """Check if the URL has expired or is about to expire."""
        age = time.time() - self.url_fetched_at
        return age >= max_age


class AudioProxyServer:
    """
    Local HTTP proxy server for DLNA audio streaming.

    Provides stable local URLs to DLNA devices while handling:
    - Qobuz URL expiration (5-minute TTL)
    - HTTP range requests for seeking
    - Streaming without full buffering

    Usage:
        url_provider = MetadataServiceURLProvider(metadata_service)
        proxy = AudioProxyServer(
            url_provider=url_provider,
            host="0.0.0.0",
            port=7120,
        )
        await proxy.start()

        # Register a track before playback
        proxy_url = proxy.register_track("12345", qobuz_url, "audio/flac")
        # proxy_url = "http://192.168.1.100:7120/audio/12345.flac"

        # Pass proxy_url to DLNA device
    """

    def __init__(
        self,
        url_provider: StreamingURLProvider,
        host: str = "0.0.0.0",
        port: int = 7120,
        url_max_age: float = DEFAULT_URL_MAX_AGE_SECONDS,
    ):
        """
        Initialize audio proxy server.

        Args:
            url_provider: Provider for fetching fresh streaming URLs
            host: Host to bind to
            port: Port to listen on
            url_max_age: Maximum URL age before refresh (seconds)
        """
        self._url_provider = url_provider
        self._host = host
        self._port = port
        self._url_max_age = url_max_age

        self._tracks: Dict[str, RegisteredTrack] = {}
        self._on_delivery_failure: Optional[Callable[[str, bool], None]] = None
        self._app: Optional[web.Application] = None
        self._runner: Optional[web.AppRunner] = None
        self._site: Optional[web.TCPSite] = None

        # Will be set after start() to actual bound address
        self._actual_host: Optional[str] = None

    @property
    def base_url(self) -> str:
        """Get the base URL for this proxy server."""
        host = self._actual_host or self._host
        # Use actual IP if bound to 0.0.0.0
        if host == "0.0.0.0":
            host = self._get_local_ip()
        return f"http://{host}:{self._port}"

    @property
    def is_running(self) -> bool:
        """Check if the server is running."""
        return self._site is not None

    async def start(self) -> None:
        """Start the proxy server."""
        self._app = web.Application()
        self._app.router.add_get("/audio/{track_id}", self._handle_audio)
        self._app.router.add_get("/audio/{track_id}.flac", self._handle_audio)
        self._app.router.add_get("/audio/{track_id}.mp3", self._handle_audio)

        self._runner = web.AppRunner(self._app)
        await self._runner.setup()

        self._site = web.TCPSite(self._runner, self._host, self._port)
        await self._site.start()

        logger.info(f"Audio proxy server started on {self._host}:{self._port}")

    async def stop(self) -> None:
        """Stop the proxy server."""
        if self._site:
            await self._site.stop()
            self._site = None
        if self._runner:
            await self._runner.cleanup()
            self._runner = None

        self._tracks.clear()
        logger.info("Audio proxy server stopped")

    def register_track(
        self,
        track_id: str,
        qobuz_url: str,
        content_type: str = "audio/flac",
        proxy_key: Optional[str] = None,
    ) -> str:
        """
        Register a track for proxying.

        Args:
            track_id: Qobuz track ID
            qobuz_url: Current Qobuz streaming URL
            content_type: MIME type of the audio
            proxy_key: Optional key for the proxy URL path (defaults to track_id).
                       Use a unique key like "{track_id}_{queue_item_id}" to produce
                       distinct proxy URLs for duplicate tracks in a queue.

        Returns:
            Local proxy URL for the track
        """
        key = proxy_key or track_id
        self._tracks[key] = RegisteredTrack(
            track_id=track_id,
            qobuz_url=qobuz_url,
            content_type=content_type,
            url_fetched_at=time.time(),
        )

        # Determine extension from content type
        ext = "flac" if "flac" in content_type else "mp3"
        proxy_url = f"{self.base_url}/audio/{key}.{ext}"

        logger.debug(f"Registered track {track_id} (key={key}) -> {proxy_url}")
        return proxy_url

    def set_delivery_failure_callback(self, callback: Callable[[str, bool], None]) -> None:
        """Register ``callback(proxy_key, before_audio)`` for streams we could not serve.

        ``before_audio`` is True when the renderer got no audio at all (an error
        response), False when the stream was cut short after audio was sent.
        """
        self._on_delivery_failure = callback

    def _report_delivery_failure(self, proxy_key: str, before_audio: bool) -> None:
        if self._on_delivery_failure:
            try:
                self._on_delivery_failure(proxy_key, before_audio)
            except Exception as e:
                logger.error(f"Delivery failure callback error: {e}")

    def unregister_track(self, track_id: str) -> None:
        """Remove a track from the registry."""
        if track_id in self._tracks:
            del self._tracks[track_id]
            logger.debug(f"Unregistered track {track_id}")

    def update_track_url(self, track_id: str, qobuz_url: str) -> None:
        """Update the Qobuz URL for a registered track."""
        if track_id in self._tracks:
            track = self._tracks[track_id]
            track.qobuz_url = qobuz_url
            track.url_fetched_at = time.time()
            logger.debug(f"Updated URL for track {track_id}")

    async def _handle_audio(self, request: web.Request) -> web.StreamResponse:
        """Handle audio stream requests from DLNA devices."""
        # Extract proxy key (remove extension if present). Note: this is the
        # registration key, not necessarily the Qobuz track ID — gapless
        # registers tracks with composite keys like "{track_id}_{queue_item_id}"
        # so duplicates in a queue get distinct proxy URLs.
        proxy_key = request.match_info["track_id"]
        proxy_key = proxy_key.rsplit(".", 1)[0]  # Remove .flac/.mp3

        # Check if track is registered
        track = self._tracks.get(proxy_key)
        if not track:
            logger.warning(f"Unknown track requested: {proxy_key}")
            return web.Response(status=404, text="Track not found")

        # Check if URL needs refresh. force=True bypasses the metadata cache:
        # its TTL is longer than the proxy's max age, so a plain fetch inside
        # the overlap window would hand back the same dying URL while resetting
        # url_fetched_at — making the proxy trust it for another full cycle.
        if track.is_url_expired(self._url_max_age):
            logger.info(f"Refreshing expired URL for track {track.track_id}")
            if not await self._refresh_track_url(track, force=True):
                if request.method != "HEAD":
                    self._report_delivery_failure(proxy_key, True)
                return web.Response(status=502, text="Failed to refresh streaming URL")

        # HEAD probes (Denon/HEOS send one before every GET) route here too via
        # add_get's implicit HEAD support. Answer them headers-only — streaming
        # the body just to have aiohttp discard it downloads the whole track
        # from the CDN.
        if request.method == "HEAD":
            return await self._handle_head_probe(track)

        # HEOS has no native seek command (see HeosClient.seek_via_reload): a
        # seek is approximated by reloading this same track via play_stream
        # with seek_ms/duration_ms appended, starting the response from a
        # byte offset elsewhere in the file. For FLAC that offset must be
        # frame-aligned and preceded by the file's own header, or no decoder
        # (HEOS included) can make sense of it - see flac_seek.py.
        synthetic_start_byte = None
        prepend_header: Optional[bytes] = None
        if not request.headers.get("Range") and "seek_ms" in request.query:
            try:
                seek_ms = int(request.query["seek_ms"])
                duration_ms = int(request.query["duration_ms"])
            except (KeyError, ValueError):
                seek_ms = duration_ms = 0
            if duration_ms > 0:
                if track.content_type == "audio/flac":
                    synthetic_start_byte, prepend_header = await self._flac_seek_offset(
                        track, seek_ms, duration_ms
                    )
                else:
                    # MP3 frames are independently decodable without a global
                    # header, so a proportional guess (the decoder resyncs on
                    # the next frame sync on its own) is good enough here.
                    content_length = await self._get_content_length(track)
                    if content_length:
                        synthetic_start_byte = max(
                            0,
                            min(
                                content_length - 1,
                                int(content_length * (seek_ms / duration_ms)),
                            ),
                        )
                if synthetic_start_byte is not None:
                    logger.info(
                        f"Seeking track {track.track_id} to {seek_ms}ms "
                        f"as byte offset {synthetic_start_byte}"
                        + (f" (+{len(prepend_header)}B header)" if prepend_header else "")
                    )

        # Forward request to Qobuz CDN
        return await self._proxy_stream(
            request,
            track,
            proxy_key,
            synthetic_start_byte=synthetic_start_byte,
            prepend_header=prepend_header,
        )

    async def _flac_seek_offset(
        self, track: RegisteredTrack, seek_ms: int, duration_ms: int
    ) -> tuple:
        """Compute (byte_offset, header_bytes) for a FLAC seek.

        Fetches and caches the file's header (magic + metadata blocks,
        including SEEKTABLE if present) once per track. Returns (None, None)
        if the header can't be determined - caller then serves the track
        unseeked rather than a broken stream.
        """
        info = track.flac_seek_info
        if info is None:
            data = await self._fetch_range(track.qobuz_url, 0, 262_143)  # 256KB
            if data:
                info = parse_flac_header(data)
            if info is None and data and len(data) >= 262_144:
                # Unusually large metadata (e.g. embedded cover art) - try
                # once more with a bigger window before giving up.
                data = await self._fetch_range(track.qobuz_url, 0, 2_097_151)  # 2MB
                if data:
                    info = parse_flac_header(data)
            if info is None:
                logger.warning(f"Could not parse FLAC header for track {track.track_id}")
                return None, None
            track.flac_seek_info = info

        exact_offset = find_seek_byte_offset(info, seek_ms)
        if exact_offset is not None:
            return exact_offset, info.header

        # No SEEKTABLE: proportional guess within the audio data region, then
        # scan a small window for the next real frame sync as a best effort.
        if info.total_samples <= 0 or info.sample_rate <= 0:
            return info.audio_data_offset, info.header
        target_sample = int((seek_ms / 1000) * info.sample_rate)
        fraction = min(1.0, max(0.0, target_sample / info.total_samples))
        content_length = await self._get_content_length(track)
        if not content_length:
            return info.audio_data_offset, info.header
        audio_bytes = content_length - info.audio_data_offset
        guess = info.audio_data_offset + int(audio_bytes * fraction)
        window = await self._fetch_range(track.qobuz_url, guess, guess + 65_535)
        if window:
            sync_at = find_next_frame_sync(window)
            if sync_at >= 0:
                return guess + sync_at, info.header
        return guess, info.header

    async def _fetch_range(self, url: str, start: int, end: int) -> Optional[bytes]:
        """Fetch bytes [start, end] (inclusive) from an upstream URL."""
        timeout = ClientTimeout(total=REQUEST_TIMEOUT_SECONDS)
        try:
            async with ClientSession(timeout=timeout) as session:
                async with session.get(
                    url, headers={"Range": f"bytes={start}-{end}"}
                ) as resp:
                    if resp.status in (200, 206):
                        return await resp.read()
        except Exception as e:
            logger.debug(f"Range fetch {start}-{end} failed: {e}")
        return None

    async def _get_content_length(self, track: RegisteredTrack) -> Optional[int]:
        """HEAD the upstream URL to learn the file size for seek-offset math."""
        timeout = ClientTimeout(total=REQUEST_TIMEOUT_SECONDS)
        try:
            async with ClientSession(timeout=timeout) as session:
                async with session.head(track.qobuz_url, allow_redirects=True) as upstream:
                    cl = upstream.headers.get("Content-Length")
                    if upstream.status in (200, 206) and cl and cl.isdigit():
                        return int(cl)
        except Exception as e:
            logger.debug(f"Content-Length HEAD failed for track {track.track_id}: {e}")
        return None

    async def _handle_head_probe(self, track: RegisteredTrack) -> web.Response:
        """Answer a HEAD probe from upstream headers, without a body transfer."""
        response = web.Response(
            status=200,
            headers={"Content-Type": track.content_type, "Accept-Ranges": "bytes"},
        )
        timeout = ClientTimeout(total=REQUEST_TIMEOUT_SECONDS)
        try:
            async with ClientSession(timeout=timeout) as session:
                async with session.head(track.qobuz_url, allow_redirects=True) as upstream:
                    cl = upstream.headers.get("Content-Length")
                    if upstream.status in (200, 206) and cl and cl.isdigit():
                        response.content_length = int(cl)
        except Exception as e:
            # A probe answer without Content-Length is still useful; renderers
            # mostly check availability and type here.
            logger.debug(f"Upstream HEAD failed for track {track.track_id}: {e}")
        return response

    async def _proxy_stream(
        self,
        request: web.Request,
        track: RegisteredTrack,
        proxy_key: str,
        synthetic_start_byte: Optional[int] = None,
        prepend_header: Optional[bytes] = None,
    ) -> web.StreamResponse:
        """Proxy the audio stream from Qobuz CDN.

        If the upstream connection dies mid-stream (the CDN occasionally aborts
        long-running transfers with a short read), reconnect with a Range
        request from the last byte delivered to the client instead of dropping
        the renderer's stream mid-track.

        synthetic_start_byte: set for a HEOS seek-via-reload (see
        HeosClient.seek_via_reload) - the client didn't ask for a Range
        itself, so the upstream Range this builds is our own doing, and the
        response is forced to plain 200 rather than 206 since HEOS thinks
        it's getting a fresh stream, not a partial one.

        prepend_header: for a FLAC seek, the file's own header bytes (magic +
        metadata blocks) written before the ranged content, since a raw
        mid-file slice alone isn't decodable - see flac_seek.py.
        """
        # Build headers for upstream request
        headers: Dict[str, str] = {}

        # Forward Range header for seeking support
        range_header = request.headers.get("Range")
        request_start = 0
        if range_header:
            headers["Range"] = range_header
            request_start = _parse_range_start(range_header)
            logger.debug(f"Proxying with Range: {range_header}")
        elif synthetic_start_byte:
            headers["Range"] = f"bytes={synthetic_start_byte}-"
            request_start = synthetic_start_byte

        # No total timeout for streaming, but a per-read timeout so a stalled
        # CDN connection fails fast instead of hanging forever.
        timeout = ClientTimeout(total=None, connect=30, sock_read=READ_TIMEOUT_SECONDS)

        response: Optional[web.StreamResponse] = None
        expected_bytes: Optional[int] = None
        is_range = range_header is not None or synthetic_start_byte is not None
        stream_start = time.monotonic()
        bytes_sent = 0
        retries = 0
        expired_url_retry_done = False

        while True:
            upstream_headers = dict(headers)
            if bytes_sent:
                upstream_headers["Range"] = f"bytes={request_start + bytes_sent}-"

            try:
                logger.debug(
                    f"Connecting to upstream URL for track {track.track_id}: "
                    f"{track.qobuz_url[:100]}..."
                )
                async with ClientSession(timeout=timeout) as session:
                    async with session.get(
                        track.qobuz_url,
                        headers=upstream_headers,
                    ) as upstream_response:
                        if upstream_response.status not in (200, 206):
                            # An expired signed URL surfaces as an error *status*
                            # (401/403/410), not an exception — refresh and retry
                            # once before failing the renderer's request.
                            if (
                                response is None
                                and not expired_url_retry_done
                                and upstream_response.status in (401, 403, 410)
                            ):
                                expired_url_retry_done = True
                                logger.info(
                                    f"Upstream {upstream_response.status} for track "
                                    f"{track.track_id} — URL likely expired; fetching "
                                    "a fresh URL and retrying"
                                )
                                if await self._refresh_track_url(track, force=True):
                                    continue
                            logger.warning(
                                f"Upstream error for track {track.track_id}: "
                                f"{upstream_response.status}"
                            )
                            self._report_delivery_failure(proxy_key, response is None)
                            if response is None:
                                return web.Response(
                                    status=502,
                                    text=f"Upstream error: {upstream_response.status}",
                                )
                            # Headers already sent — nothing more we can do
                            return response

                        if bytes_sent and upstream_response.status != 206:
                            # Upstream ignored our resume Range; restarting from
                            # byte 0 would corrupt the audio stream
                            logger.error(
                                f"Upstream ignored resume Range for track {track.track_id}; "
                                "aborting stream"
                            )
                            self._report_delivery_failure(proxy_key, False)
                            assert response is not None
                            return response

                        if response is None:
                            # First successful connection: send headers to client.
                            # A synthetic seek forces 200 (with no Content-Range)
                            # even though upstream gave us 206 - HEOS never asked
                            # for a Range itself, so it must see a plain stream.
                            status = (
                                200
                                if synthetic_start_byte is not None
                                else (206 if upstream_response.status == 206 else 200)
                            )
                            response_headers: Dict[str, str] = {
                                "Content-Type": track.content_type,
                                "Accept-Ranges": "bytes",
                            }
                            if "Content-Length" in upstream_response.headers:
                                cl = upstream_response.headers["Content-Length"]
                                if cl.isdigit():
                                    expected_bytes = int(cl)
                                    total = expected_bytes + (
                                        len(prepend_header) if prepend_header else 0
                                    )
                                    response_headers["Content-Length"] = str(total)
                            if (
                                synthetic_start_byte is None
                                and "Content-Range" in upstream_response.headers
                            ):
                                response_headers["Content-Range"] = upstream_response.headers[
                                    "Content-Range"
                                ]

                            logger.debug(
                                f"Streaming track {track.track_id}, headers: {response_headers}"
                            )
                            response = web.StreamResponse(
                                status=status,
                                headers=response_headers,
                            )
                            await response.prepare(request)
                            if prepend_header:
                                await response.write(prepend_header)

                        # Stream chunks to client
                        async for chunk in upstream_response.content.iter_chunked(
                            STREAM_CHUNK_SIZE
                        ):
                            if proxy_key not in self._tracks:
                                # Unregistered mid-transfer: a request that
                                # passed the registration check right before a
                                # track switch unregistered it (a real race -
                                # HEOS can open a fresh connection a moment
                                # before we cut the old one over). Checking
                                # only once up front let a stale stream run to
                                # completion and play audibly; checking here
                                # too cuts it off as soon as it goes stale.
                                logger.info(
                                    f"Track {track.track_id} unregistered mid-stream; "
                                    f"stopping stale transfer at {bytes_sent} bytes"
                                )
                                await response.write_eof()
                                return response
                            try:
                                await response.write(chunk)
                                bytes_sent += len(chunk)
                            except (ConnectionResetError, ConnectionError):
                                self._log_stream_end(
                                    track=track,
                                    bytes_sent=bytes_sent,
                                    expected_bytes=expected_bytes,
                                    elapsed=time.monotonic() - stream_start,
                                    is_range=is_range,
                                    completed=False,
                                )
                                return response

                await response.write_eof()
                self._log_stream_end(
                    track=track,
                    bytes_sent=bytes_sent,
                    expected_bytes=expected_bytes,
                    elapsed=time.monotonic() - stream_start,
                    is_range=is_range,
                    completed=True,
                )
                return response

            except asyncio.CancelledError:
                logger.debug(f"Stream cancelled for track {track.track_id}")
                raise
            except (ClientError, asyncio.TimeoutError) as e:
                # Upstream-side failure — retry with a Range resume
                retries += 1
                if retries > MAX_UPSTREAM_RETRIES:
                    logger.error(
                        f"Upstream failed for track {track.track_id} after "
                        f"{MAX_UPSTREAM_RETRIES} retries: {type(e).__name__}: {e}"
                    )
                    self._report_delivery_failure(proxy_key, response is None)
                    if response is None:
                        return web.Response(status=502, text=f"Upstream error: {e}")
                    self._log_stream_end(
                        track=track,
                        bytes_sent=bytes_sent,
                        expected_bytes=expected_bytes,
                        elapsed=time.monotonic() - stream_start,
                        is_range=is_range,
                        completed=False,
                    )
                    return response
                logger.warning(
                    f"Upstream connection lost for track {track.track_id} after "
                    f"{bytes_sent} bytes ({type(e).__name__}: {e}); "
                    f"reconnecting ({retries}/{MAX_UPSTREAM_RETRIES})"
                )
                await asyncio.sleep(UPSTREAM_RETRY_DELAY_SECONDS * retries)
                await self._refresh_track_url(track, force=True)
            except (ConnectionResetError, ConnectionError) as e:
                # Client disconnected - this is normal when Sonos probes or seeks
                logger.debug(
                    f"Client connection closed for track {track.track_id}: {type(e).__name__}"
                )
                if response is not None:
                    return response
                return web.Response(status=499, text="Client closed connection")
            except Exception as e:
                logger.error(f"Proxy error for track {track.track_id}: {type(e).__name__}: {e}")
                logger.error(f"URL was: {track.qobuz_url[:100]}...")
                logger.debug(f"Full traceback: {traceback.format_exc()}")
                self._report_delivery_failure(proxy_key, response is None)
                if response is not None:
                    return response
                return web.Response(status=502, text=f"Proxy error: {e}")

    async def _refresh_track_url(self, track: RegisteredTrack, force: bool = False) -> bool:
        """Fetch a fresh streaming URL before retrying (signed URLs can go stale).

        force=True bypasses the URL provider's cache — required whenever the
        current URL is known or suspected dead, since a cached "valid" URL may
        be the very one that just failed.

        Returns:
            True if a fresh URL was applied, False if the refresh failed.
        """
        try:
            fresh_url = await self._url_provider.get_streaming_url(track.track_id, force=force)
            track.qobuz_url = fresh_url
            track.url_fetched_at = time.time()
            return True
        except Exception as e:
            logger.warning(
                f"Could not refresh URL for track {track.track_id}: {e}; retrying with old URL"
            )
            return False

    def _log_stream_end(
        self,
        track: RegisteredTrack,
        bytes_sent: int,
        expected_bytes: Optional[int],
        elapsed: float,
        is_range: bool,
        completed: bool,
    ) -> None:
        """Log the outcome of a proxied stream with throughput diagnostics.

        Distinguishes a genuine mid-stream drop (renderer gave up or its buffer
        underran) from benign disconnects (a Sonos probe, a seek, or a finished
        transfer). Average throughput is included so we can tell *which*: a low
        Mbit/s well under the stream bitrate points at the proxy/network not
        keeping the device's buffer full; a high rate that simply stops points
        at the renderer being unable to sustain decode/output at this quality.
        """
        rate_mbps = (bytes_sent * 8 / elapsed / 1_000_000) if elapsed > 0 else 0.0
        pct = f"{bytes_sent / expected_bytes * 100:.1f}%" if expected_bytes else "?"

        # A mid-transfer drop: a full-body request (not a range/seek) that ended
        # well short of the advertised length. This is the stutter/stop symptom.
        short = expected_bytes is not None and bytes_sent < expected_bytes * 0.95
        if not completed and short and not is_range:
            logger.warning(
                "Renderer dropped track %s mid-stream: sent %d/%d bytes (%s) in "
                "%.1fs (%.2f Mbit/s avg). Suspect buffer underrun or renderer "
                "cannot sustain this quality.",
                track.track_id,
                bytes_sent,
                expected_bytes,
                pct,
                elapsed,
                rate_mbps,
            )
        elif completed:
            logger.debug(
                "Finished streaming track %s: %d bytes in %.1fs (%.2f Mbit/s avg)",
                track.track_id,
                bytes_sent,
                elapsed,
                rate_mbps,
            )
        else:
            logger.debug(
                "Client disconnected after %d bytes (%s) for track %s "
                "(range=%s, %.1fs, %.2f Mbit/s avg)",
                bytes_sent,
                pct,
                track.track_id,
                is_range,
                elapsed,
                rate_mbps,
            )

    def _get_local_ip(self) -> str:
        """Get local IP address for proxy URL."""
        try:
            # Connect to external address to determine local IP
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            s.close()
            return ip
        except Exception:
            return "127.0.0.1"

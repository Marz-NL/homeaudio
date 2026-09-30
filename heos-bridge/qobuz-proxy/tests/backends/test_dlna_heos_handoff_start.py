"""A handoff mid-track on HEOS starts the stream at that position right away.

HEOS has no seek command, so seeking means reloading from a byte offset via the
audio proxy. Starting at 0 and reloading once the player seeks played the first
seconds of the track before jumping; the first play_stream now carries the
offset itself.
"""

from unittest.mock import MagicMock

import pytest

from qobuz_proxy.backends.dlna.backend import DLNABackend
from qobuz_proxy.backends.dlna.heos_client import HeosClient
from qobuz_proxy.backends.types import BackendTrackMetadata

PROXY_URI = "http://proxy:7120/audio/123.flac"


@pytest.fixture
def backend():
    backend = DLNABackend("192.0.2.1", name="HEOS")
    client = MagicMock(spec=HeosClient)
    client.set_av_transport_uri.return_value = True
    client.play.return_value = True
    backend._client = client
    backend._proxy_server = MagicMock()
    backend._proxy_server.register_track.return_value = PROXY_URI
    return backend


def _meta(**kwargs) -> BackendTrackMetadata:  # type: ignore[no-untyped-def]
    return BackendTrackMetadata(track_id="123", title="T", **kwargs)


async def test_handoff_starts_the_stream_at_the_position(backend):
    await backend._play("https://qobuz/file", _meta(duration_ms=180_000, start_position_ms=30_000))

    played_url = backend._client.set_av_transport_uri.await_args.args[0]
    assert played_url == f"{PROXY_URI}?seek_ms=30000&duration_ms=180000"
    assert backend.started_at_ms == 30_000
    assert backend._position_ms == 30_000
    # The original url stays the current one, like after seek_via_reload
    assert backend._current_proxy_url == PROXY_URI
    backend._client.note_started_at.assert_called_once_with(PROXY_URI, 30_000)


async def test_unknown_duration_starts_from_the_beginning(backend):
    await backend._play("https://qobuz/file", _meta(duration_ms=0, start_position_ms=30_000))

    assert backend._client.set_av_transport_uri.await_args.args[0] == PROXY_URI
    assert backend.started_at_ms == 0
    backend._client.note_started_at.assert_not_called()


async def test_normal_play_is_unchanged(backend):
    backend.started_at_ms = 30_000  # left over from an earlier handoff
    await backend._play("https://qobuz/file", _meta(duration_ms=180_000))

    assert backend._client.set_av_transport_uri.await_args.args[0] == PROXY_URI
    assert backend.started_at_ms == 0
    assert backend._position_ms == 0

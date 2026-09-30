"""The player skips its post-start seek when the backend already started there."""

from unittest.mock import AsyncMock

import pytest

from qobuz_proxy.backends import BackendTrackMetadata
from qobuz_proxy.playback.command_handler import PlaybackCommandHandler

from tests.playback.test_command_handler_set_state import _set_active_msg, _set_state_msg
from tests.playback.test_player_serialization import _make_player


@pytest.mark.parametrize("backend_starts_there", [True, False])
async def test_handoff_seeks_only_when_the_backend_did_not_start_there(
    backend_starts_there,
) -> None:
    player, backend = _make_player()
    starts: list[int] = []

    async def play(url: str, metadata: BackendTrackMetadata) -> None:
        starts.append(metadata.start_position_ms)
        backend.started_at_ms = metadata.start_position_ms if backend_starts_there else 0

    backend.play = play  # type: ignore[method-assign]
    backend.seek = AsyncMock()  # type: ignore[method-assign]
    handler = PlaybackCommandHandler(player)
    await handler._handle_set_active(_set_active_msg(True))

    await handler._handle_set_state(
        _set_state_msg(track_id=2001, queue_item_id=1, playing_state=2, position_ms=30_000)
    )

    assert starts == [30_000]
    if backend_starts_there:
        backend.seek.assert_not_awaited()
    else:
        backend.seek.assert_awaited_once_with(30_000)

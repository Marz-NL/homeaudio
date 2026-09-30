#!/bin/bash
# Run by player-guard-helper when Music Assistant is connected from playerui:
# MA_URL and MA_TOKEN come from the page, everything else from the room's
# remembered answers. Output streams to the page.
export HOMEAUDIO_JOB=1
# passed on under their own names: remembered answers mustn't override them
export MA_URL_GIVEN="${MA_URL:-}" MA_TOKEN_GIVEN="${MA_TOKEN:-}"
exec "$(dirname "$(readlink -f "$0")")/../../install.sh" --yes add ma

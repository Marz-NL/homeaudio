#!/bin/bash
# Run by player-guard-helper for playerui's "Add a source": no questions asked
# (--yes), the room's remembered answers are used. Output streams to the page.
export HOMEAUDIO_JOB=1
exec "$(dirname "$(readlink -f "$0")")/../../install.sh" --yes add qobuz

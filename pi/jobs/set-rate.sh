#!/bin/bash
# Run by player-guard-helper when the output rate is switched in playerui.
# RATE comes from the page: native | 44100 | 48000 (install.sh checks it).
export HOMEAUDIO_JOB=1
exec "$(dirname "$(readlink -f "$0")")/../../install.sh" --yes rate "${RATE:-}"

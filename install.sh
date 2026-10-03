#!/bin/bash
# homeaudio installer - one script per machine.
#
#   sudo ./install.sh room             a Pi with a DAC: player-guard, playerui, sources
#   sudo ./install.sh add <source>     add a source to a room later: ma | qobuz | spotify | airplay
#   sudo ./install.sh rate <rate>      output: native (no conversion) | 44100 | 48000 (CamillaDSP,
#                                      switched live) | direct (no CamillaDSP, the default)
#   ./install.sh hub                   a Docker host: one overview page for every room
#   sudo ./install.sh heos             bridge a HEOS speaker to Qobuz Connect (Pi or homelab)
#   ./install.sh doctor                check what is installed and running
#   sudo ./install.sh uninstall        remove it all again (--purge: also answers and app logins)
#
# Roles combine, e.g. `sudo ./install.sh room heos` on a Pi that also runs the
# HEOS bridge. Answers are remembered in /etc/homeaudio/install.conf, so a
# re-run asks nothing and updates what changed.
#
# Options:
#   --dry-run      show what would happen, change nothing
#   --yes          take the default for every question
#   --reconfigure  ask every question again (remembered answers are the defaults)
#   --no-docker    heos: install into a Python venv + systemd instead of Docker

set -euo pipefail
HOMEAUDIO=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
LOG=/var/log/homeaudio-install.log

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

ROLES=()
ADD=()
RATE=
NO_DOCKER=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)     export DRY_RUN=1 ;;
    --yes|-y)      export ASSUME_YES=1 ;;
    --reconfigure) export RECONFIGURE=1 ;;
    --no-docker)   NO_DOCKER=1 ;;
    --purge)       export PURGE=1 ;;
    -h|--help)     usage ;;
    room|hub|heos|doctor|uninstall) ROLES+=("$1") ;;
    add)           shift; [ $# -gt 0 ] || usage 1; ADD+=("$1") ;;
    rate)          shift; [ $# -gt 0 ] || usage 1; RATE=$1 ;;
    *)             echo "Unknown: $1"; usage 1 ;;
  esac
  shift
done
[ ${#ROLES[@]} -gt 0 ] || [ ${#ADD[@]} -gt 0 ] || [ -n "$RATE" ] || usage 1

. "$HOMEAUDIO/lib/common.sh"
. "$HOMEAUDIO/lib/dac.sh"
. "$HOMEAUDIO/lib/output.sh"

# Everything also goes to the log, for when something needs explaining later
# (not for doctor: that one only looks)
if [ -z "${DRY_RUN:-}" ] && [ "$(id -u)" -eq 0 ] && [ "${ROLES[*]}" != doctor ]; then
  exec > >(tee -a "$LOG") 2>&1
  printf '\n######## %s  install.sh %s\n' "$(date '+%F %T')" "${ROLES[*]} ${ADD[*]:+add ${ADD[*]}}${RATE:+ rate $RATE}"
fi

conf_load
for role in "${ROLES[@]}"; do
  [ -f "$HOMEAUDIO/lib/$role.sh" ] || die "the '$role' role isn't in this version yet - see README.md for the manual way"
  . "$HOMEAUDIO/lib/$role.sh"
  "${role}_main"
done
if [ ${#ADD[@]} -gt 0 ]; then
  . "$HOMEAUDIO/lib/room.sh"
  for src in "${ADD[@]}"; do room_add_source "$src"; done
fi
if [ -n "$RATE" ]; then
  . "$HOMEAUDIO/lib/room.sh"
  out_set_rate "$RATE"
fi

[ -n "${DRY_RUN:-}" ] && say "Dry run: nothing was changed."
[ -z "${DRY_RUN:-}" ] && [ "$(id -u)" -eq 0 ] && [ "${ROLES[*]}" != doctor ] && info "Log: $LOG"
exit 0

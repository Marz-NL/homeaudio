#!/bin/bash
# Migration for a room set up before the group was called playerguard (it was audioguard).
# Run once per room, as root, after the new player-guard-helper is in /usr/local/bin:
#   sudo bash lib/migrate-playerguard.sh
# Changes nothing when the group is already playerguard.
#
# groupmod -n renames the group and keeps its id: its members stay in it, and the files
# that belong to it (/etc/player-guard.env, the helper's socket) keep their owner.
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

# The old helper names the group audioguard: rename only with the new build in place
if ! strings /usr/local/bin/player-guard-helper 2>/dev/null | grep -q playerguard; then
  echo "player-guard-helper is the old build: install the new one first. Nothing changed."
  exit 1
fi

if getent group playerguard >/dev/null; then
  echo "group playerguard exists: nothing to rename"
elif getent group audioguard >/dev/null; then
  groupmod -n playerguard audioguard
  echo "renamed group audioguard -> playerguard"
else
  echo "no audioguard group: nothing to rename"
fi

# Check: the members and the env file are in playerguard
echo "members: $(getent group playerguard | cut -d: -f4)"
echo "env file group: $(stat -c %G /etc/player-guard.env 2>/dev/null || echo none)"

# playerui runs as this group: its unit names it, so the unit follows the rename
if grep -q '^Group=audioguard' /etc/systemd/system/playerui.service 2>/dev/null; then
  sed -i 's/^Group=audioguard/Group=playerguard/' /etc/systemd/system/playerui.service
  systemctl daemon-reload
  echo "playerui unit: Group=playerguard"
fi

# The helper and the web page read the group when they start. The sources keep
# their membership (it was renamed with the group), so they're not restarted.
systemctl restart player-guard-helper playerui
echo "done: $(systemctl is-active player-guard-helper) helper, $(systemctl is-active playerui) playerui"

#!/bin/bash
# Migration for a room set up before the guard group was renamed. Run once per room, as
# root, after the new player-guard-helper is in /usr/local/bin:
#   sudo bash lib/migrate-playerguard.sh
# Changes nothing when the new group already exists and the old one is gone.
#
# groupmod -n renames the group and keeps its id: its members stay in it, and the files
# that belong to it (/etc/player-guard.env, the helper's socket) keep their owner.
set -eu
OLD_GROUP=audioguard
NEW_GROUP=playerguard              # GUARD_GROUP in lib/common.sh
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

# The old helper sets the socket to the old group: rename only with the new build in place
if ! strings /usr/local/bin/player-guard-helper 2>/dev/null | grep -q "$NEW_GROUP"; then
  echo "player-guard-helper is the old build: install the new one first. Nothing changed."
  exit 1
fi

if getent group "$NEW_GROUP" >/dev/null; then
  echo "group $NEW_GROUP exists: nothing to rename"
elif getent group "$OLD_GROUP" >/dev/null; then
  groupmod -n "$NEW_GROUP" "$OLD_GROUP"
  echo "renamed group $OLD_GROUP -> $NEW_GROUP"
else
  echo "no $OLD_GROUP group: nothing to rename"
fi

# Check: the members and the env file are in the new group
echo "members: $(getent group "$NEW_GROUP" | cut -d: -f4)"
echo "env file group: $(stat -c %G /etc/player-guard.env 2>/dev/null || echo none)"

# playerui runs as this group: its unit names it, so the unit follows the rename
if grep -q "^Group=$OLD_GROUP" /etc/systemd/system/playerui.service 2>/dev/null; then
  sed -i "s/^Group=$OLD_GROUP/Group=$NEW_GROUP/" /etc/systemd/system/playerui.service
  systemctl daemon-reload
  echo "playerui unit: Group=$NEW_GROUP"
fi

# The helper and the web page read the group when they start. The sources keep
# their membership (it was renamed with the group), so they're not restarted.
systemctl restart player-guard-helper playerui
echo "done: $(systemctl is-active player-guard-helper) helper, $(systemctl is-active playerui) playerui"

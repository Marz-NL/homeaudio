# Source: Music Assistant (you run it yourself, anywhere on the network).
# This connects the room to it: sendspin as its player, driving the DAC's
# hardware volume, and the player id player-guard uses to ask it to stop.

src_ma_questions() {
  say "Music Assistant"
  local tries=0 code url_default=""
  while :; do
    ask MA_URL "Music Assistant address, e.g. http://homeassistant.local:8095" "$url_default"
    [ -n "$MA_URL" ] || die "Music Assistant needs its address"
    conf_set MA_URL "${MA_URL%/}"
    info "Token: in Music Assistant itself (not Home Assistant):"
    info "Settings > Profile > Long-lived access tokens > create one, copy it whole."
    ask_secret MA_TOKEN "Music Assistant token (typing is hidden)"
    [ -n "$DRY_RUN" ] && return 0

    code=$(ma_http_code)
    [ "$code" = 200 ] && { info "Music Assistant answers at $MA_URL"; return 0; }
    case "$code" in
      401|403) warn "Music Assistant at $MA_URL rejected that token" ;;
      000)     warn "nothing answers at $MA_URL - check the address and port (usually 8095)" ;;
      *)       warn "Music Assistant at $MA_URL answered with HTTP $code" ;;
    esac
    # Forget what was wrong, so it's asked again - now or on the next run
    conf_unset MA_TOKEN
    if [ "$code" != 401 ] && [ "$code" != 403 ]; then url_default=$MA_URL; conf_unset MA_URL; fi
    tries=$((tries + 1))
    if [ "$tries" -ge 3 ] || [ -n "$ASSUME_YES" ] || [ ! -t 0 ]; then
      die "Music Assistant not connected - run 'sudo ./install.sh add ma' to try again"
    fi
    info "Try again:"
  done
}

# HTTP status of an authenticated players/all call (000: no answer at all)
ma_http_code() {
  curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$MA_URL/api" \
    -H "Content-Type: application/json" -H "Authorization: Bearer $MA_TOKEN" \
    -d '{"message_id":"install","command":"players/all","args":{}}'
}

# ma_api <command> [args-json]: Music Assistant's JSON API, result on stdout
ma_api() {
  curl -fsS -m 5 -X POST "$MA_URL/api" -H "Content-Type: application/json" \
    -H "Authorization: Bearer $MA_TOKEN" \
    -d "{\"message_id\":\"install\",\"command\":\"$1\",\"args\":${2:-{\}}}"
}

src_ma_install() {
  say "Music Assistant player (sendspin)"
  local home; home=$(getent passwd "$AUDIO_USER" | cut -d: -f6)
  if [ ! -x "$home/.local/bin/sendspin" ]; then
    run sudo -u "$AUDIO_USER" sh -c 'command -v uv >/dev/null || [ -x "$HOME/.local/bin/uv" ] || curl -LsSf https://astral.sh/uv/install.sh | sh'
    run sudo -u "$AUDIO_USER" sh -c '$HOME/.local/bin/uv tool install sendspin'
  fi
  local device hwvol=""
  device=$(ma_sendspin_device "$home")
  [ -n "${MIXER_CONTROL:-}" ] && hwvol=" --hardware-volume true"
  write_file /etc/systemd/system/sendspin.service <<EOF
[Unit]
Description=Music Assistant player ($ROOM_NAME, sendspin)
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=$AUDIO_USER
SupplementaryGroups=audio
ExecStart=$home/.local/bin/sendspin daemon --name "$ROOM_NAME" --audio-device "$device"$hwvol
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  local cmd
  for cmd in stop pause play; do
    write_file "/usr/local/bin/ma-$cmd" 755 <<EOF
#!/bin/sh
. /etc/player-guard.env
curl -s -m 3 -X POST "\$MA_URL/api" -H "Content-Type: application/json" \\
  -H "Authorization: Bearer \$MA_TOKEN" \\
  -d "{\"message_id\":\"g\",\"command\":\"players/cmd/$cmd\",\"args\":{\"player_id\":\"\$MA_PLAYER\"}}" >/dev/null
EOF
  done
  run systemctl daemon-reload
  run systemctl enable sendspin >/dev/null 2>&1
  run systemctl restart sendspin
  ma_find_player
}

# sendspin's own name for the DAC: the entry on the card's hw:<n>,0
ma_sendspin_device() {
  local n name
  n=$(basename "$(readlink -f "/proc/asound/$DAC_CARD")" | tr -dc '0-9')
  [ -n "$DRY_RUN" ] && { echo "$DAC_CARD"; return 0; }
  name=$(sudo -u "$AUDIO_USER" "$1/.local/bin/sendspin" audio-devices list 2>/dev/null |
         sed -nE "s/^ *\[[0-9]+\] ([^:]+): .*\(hw:$n,0\).*/\1/p" | head -1)
  echo "${name:-$DAC_CARD}"
}

# The player id Music Assistant gave this room (its universal player, "up..."),
# found by name once sendspin has registered
ma_find_player() {
  [ -n "$DRY_RUN" ] && return 0
  local i id=""
  info "waiting for Music Assistant to see \"$ROOM_NAME\"..."
  for i in $(seq 1 30); do
    id=$(ma_api players/all 2>/dev/null | jq -r --arg n "$ROOM_NAME" '
      (.result // .) | map(select((.display_name // .name) == $n))
      | (map(select(.player_id | startswith("up"))) + .)[0].player_id // empty')
    [ -n "$id" ] && break
    sleep 2
  done
  if [ -n "$id" ]; then
    conf_set MA_PLAYER "$id"
    info "Music Assistant player: $id"
  else
    warn "Music Assistant doesn't show \"$ROOM_NAME\" yet; re-run 'sudo ./install.sh add ma' once it does"
  fi
}

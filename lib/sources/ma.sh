# Source: Music Assistant (you run it yourself, anywhere on the network).
# This connects the room to it: sendspin as its player, driving the DAC's
# hardware volume, and the player id player-guard uses to ask it to stop.

src_ma_questions() {
  say "Music Assistant"
  local tries=0 code url_default
  # From playerui's form: these win over remembered (possibly wrong) answers
  [ -n "${MA_URL_GIVEN:-}" ] && MA_URL=${MA_URL_GIVEN%/}
  [ -n "${MA_TOKEN_GIVEN:-}" ] && MA_TOKEN=$MA_TOKEN_GIVEN
  url_default=${MA_FOUND:-$(ma_discover)}   # MA_FOUND: room_questions looked already
  [ -n "$url_default" ] && [ -z "${MA_URL:-}" ] && [ -z "${MA_FOUND:-}" ] && info "found Music Assistant at $url_default"
  # Given by playerui (or the environment): use them without asking
  [ -n "${MA_URL:-}" ] && [ -n "$ASSUME_YES" ] && url_default=$MA_URL
  [ -z "${MA_URL:-}" ] && [ -n "$ASSUME_YES" ] && [ -n "$url_default" ] && MA_URL=$url_default
  while :; do
    ask MA_URL "Music Assistant address, e.g. http://homeassistant.local:8095" "$url_default"
    [ -n "$MA_URL" ] || die "Music Assistant needs its address"
    conf_set MA_URL "${MA_URL%/}"
    if [ -z "${MA_TOKEN:-}" ] || [ -n "$RECONFIGURE" ]; then
      info "Token: in Music Assistant itself (not Home Assistant):"
      info "Settings > Profile > Long-lived access tokens > create one, copy it whole."
    fi
    ask_secret MA_TOKEN "Music Assistant token (typing is hidden)"
    [ -n "$DRY_RUN" ] && return 0

    code=$(ma_http_code)
    if [ "$code" = 200 ]; then
      info "Music Assistant answers at $MA_URL"
      conf_set MA_URL "$MA_URL"; conf_set MA_TOKEN "$MA_TOKEN"   # keep only answers that work
      return 0
    fi
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

# The first Music Assistant server announcing itself on the LAN (mDNS _mass._tcp)
ma_discover() {
  command -v avahi-browse >/dev/null || return 0
  timeout 6 avahi-browse -rtp _mass._tcp 2>/dev/null |
    sed -n 's/^=;[^;]*;IPv4;.*"base_url=\([^"]*\)".*/\1/p' | head -1
}

# HTTP status of an authenticated players/all call (000: no answer at all)
ma_http_code() {
  curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$MA_URL/api" \
    -H "Content-Type: application/json" -H "Authorization: Bearer ${MA_TOKEN:-}" \
    -d '{"message_id":"install","command":"players/all","args":{}}'
}

# ma_api <command> [args-json]: Music Assistant's JSON API, result on stdout
ma_api() {
  curl -fsS -m 5 -X POST "$MA_URL/api" -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${MA_TOKEN:-}" \
    -d "{\"message_id\":\"install\",\"command\":\"$1\",\"args\":${2:-{\}}}"
}

src_ma_install() {
  say "Music Assistant player (sendspin)"
  local home; home=$(getent passwd "$AUDIO_USER" | cut -d: -f6)
  apt_install libportaudio2   # sendspin plays through PortAudio; without it it can't start
  if [ ! -x "$home/.local/bin/sendspin" ]; then
    info "installing sendspin (via uv)"
    run sudo -u "$AUDIO_USER" sh -c 'command -v uv >/dev/null || [ -x "$HOME/.local/bin/uv" ] || curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 INSTALLER_PRINT_QUIET=1 sh'
    run sudo -u "$AUDIO_USER" sh -c '$HOME/.local/bin/uv tool install -q sendspin 2>&1 | grep -v "is not on your PATH" || true'
  fi
  ma_write_unit "$home"
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
  # Only wait for Music Assistant when the player actually stays up
  if [ -z "$DRY_RUN" ]; then
    sleep 5
    if ! systemctl is-active -q sendspin && dac_busy; then
      # PortAudio can't see a DAC that's in use, so sendspin can't start yet
      warn "the DAC is in use (something is playing): sendspin starts by itself once it's free"
      [ -n "${MA_PLAYER:-}" ] || warn "then run 'sudo ./install.sh add ma' to finish"
      return 0
    elif ! systemctl is-active -q sendspin; then
      warn "sendspin doesn't start - its last words:"
      journalctl -u sendspin -n 8 -o cat --no-pager | sed 's/^/        /'
      warn "fix that, then: sudo ./install.sh add ma"
      return 0
    fi
    info "sendspin runs as \"$ROOM_NAME\" on $(ma_sendspin_device)"
  fi
  ma_find_player
}

# The sendspin unit: its name, the DAC (or the fixed-rate device), hardware volume
ma_write_unit() {
  local device hwvol=""
  device=$(ma_sendspin_device)
  # On the DAC's mixer like Spotify and AirPlay: the one level they all share
  # (sendspin's own default when it finds a mixer; said explicitly here)
  [ -n "${MIXER_CONTROL:-}" ] && ! out_cdsp && hwvol=" --hardware-volume true"
  write_file /etc/systemd/system/sendspin.service <<EOF
[Unit]
Description=Music Assistant player ($ROOM_NAME, sendspin)
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=$AUDIO_USER
SupplementaryGroups=audio
ExecStart=$1/.local/bin/sendspin daemon --name "$ROOM_NAME"${SENDSPIN_ID:+ --id "$SENDSPIN_ID"} --audio-device "$device"$hwvol
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

# Output rate switched: new unit, restart (Music Assistant reconnects)
src_ma_output() {
  local home; home=$(getent passwd "$AUDIO_USER" | cut -d: -f6)
  ma_write_unit "$home"
  run systemctl daemon-reload
  run systemctl restart sendspin
}

# The name sendspin opens the DAC by: PortAudio's device name starts with the
# card's long name, the part after " - " in /proc/asound/cards (E30,
# snd_rpi_hifiberry_digi, ...). Read from there rather than asked from
# sendspin: PortAudio leaves a DAC that's in use out of its list. (sendspin's
# hw:CARD=... names pass its startup check but fail once a stream starts.)
ma_sendspin_device() {
  local name
  out_cdsp && { echo "$OUT_PCM"; return 0; }   # PortAudio lists it by its hint
  name=$(dac_list | awk -F'|' -v c="$DAC_CARD" '$1 == c { sub(/^.* - /, "", $2); print $2 }')
  echo "${name:-$DAC_CARD}"
}

# Is another program playing on the DAC right now?
dac_busy() { ! grep -q closed "/proc/asound/$DAC_CARD/pcm0p/sub0/status" 2>/dev/null; }

# The player id Music Assistant gave this room (its universal player, "up..."),
# found by name once sendspin has registered
ma_find_player() {
  [ -n "$DRY_RUN" ] && return 0
  local i id=""
  info "waiting for Music Assistant to see \"$ROOM_NAME\"..."
  # By name; else by what identifies this Pi anywhere in the player's details
  # (sendspin's client id, this Pi's addresses): Music Assistant keeps the name
  # it first saw, so after a rename or a reinstall the name doesn't match.
  local cid="sendspin-cli-$(uname -n)" ips
  ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$' | paste -sd' ')
  for i in $(seq 1 30); do
    # players/all answers a plain list (older servers: {"result": [...]});
    # a failed lookup must never stop the installer
    id=$(ma_api players/all 2>/dev/null | jq -r --arg n "$ROOM_NAME" --arg cid "$cid" --arg ips "$ips" '
      ((if type == "object" then .result else . end) // []) as $all
      | ($ips | split(" ") | map(select(. != ""))) as $ip
      | ($all | map(select((.display_name // .name) == $n))) as $byname
      | ($all | map(select([.. | strings] | any(. == $cid or (. as $s | $ip | any(. as $a | $s == $a or ($s | startswith($a + ":")))))))) as $byid
      | (($byname + $byid) | map(select(.player_id | startswith("up"))) + $byname + $byid)[0].player_id // empty' 2>/dev/null || true)
    [ -n "$id" ] && break
    sleep 2
  done
  if [ -n "$id" ]; then
    conf_set MA_PLAYER "$id"
    local shown
    shown=$(ma_api players/all 2>/dev/null | jq -r --arg id "$id" '((if type == "object" then .result else . end) // [])
      | map(select(.player_id == $id))[0] | (.display_name // .name) // empty' 2>/dev/null || true)
    info "Music Assistant player: $id${shown:+ (\"$shown\")}"
    if [ -n "$shown" ] && [ "$shown" != "$ROOM_NAME" ]; then
      info "Music Assistant still calls it \"$shown\" - rename it there (Settings > Players) if you like"
    fi
  else
    warn "Music Assistant doesn't show \"$ROOM_NAME\" yet; re-run 'sudo ./install.sh add ma' once it does"
  fi
}

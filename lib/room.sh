# Room role: a Pi with a DAC - player-guard, playerui, now-playing and the
# chosen sources. Sourced by install.sh.

REPO_URL=${HOMEAUDIO_REPO:-https://github.com/Marz-NL/homeaudio}
RELEASE_URL=${HOMEAUDIO_RELEASE_URL:-$REPO_URL/releases/latest/download}
ENV_FILE=/etc/player-guard.env
MANIFEST=/etc/player-guard-services.toml
SOURCES="ma qobuz spotify airplay"

room_main() {
  need_root room
  room_checks
  room_adopt                # a room set up before this installer: keep what it has
  room_questions            # every question first, then no more waiting on input
  local src chosen=""
  for src in $SOURCES; do
    local want=WANT_${src^^}
    [ "${!want:-n}" = y ] || continue
    chosen="$chosen $src"
    . "$HOMEAUDIO/lib/sources/$src.sh"
    "src_${src}_questions"
  done
  room_base
  out_write_alsa_conf       # CamillaDSP, or nothing: sources straight on the DAC
  room_guard
  room_webui
  room_nowplaying
  for src in $chosen; do "src_${src}_install"; done
  room_env                  # again: sources may have added answers (MA player id)
  room_manifest
  room_start
  room_summary
}

# `install.sh add <source>`: also what playerui's "Add a source" runs
room_add_source() {
  local src=$1
  need_root add "$src"
  case " $SOURCES " in *" $src "*) ;; *) die "unknown source '$src' (one of: $SOURCES)" ;; esac
  [ -n "${ROOM_NAME:-}" ] || die "no room set up yet - run: sudo ./install.sh room"
  conf_set "WANT_${src^^}" y
  . "$HOMEAUDIO/lib/sources/$src.sh"
  "src_${src}_questions"
  room_env
  "src_${src}_install"
  room_env
  room_manifest
  room_start
}

# ---------------------------------------------------------------- checks

room_checks() {
  say "Checking this Pi"
  [ "$(uname -m)" = aarch64 ] || die "needs 64-bit Raspberry Pi OS (this is $(uname -m))"
  . /etc/os-release
  info "$PRETTY_NAME, $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'unknown model')"
  [ "${VERSION_CODENAME:-}" = trixie ] || warn "tested on Debian 13 (trixie) only, this is ${VERSION_CODENAME:-unknown}"
}

# ---------------------------------------------------------------- adopt

# A room set up by hand or by an older version, without install.conf yet:
# take over its answers from what's there, so it keeps its name, DAC, volume,
# sources, Music Assistant connection (token included - it never leaves this
# Pi) and sendspin id (Music Assistant knows the player by it).
room_adopt() {
  [ -f "$ENV_FILE" ] && [ -z "${ROOM_NAME:-}" ] || return 0
  say "Taking over this room's current setup"
  local v unit
  v() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1; }
  [ -n "$(v USB_CARD)" ]   && conf_set DAC_CARD "$(v USB_CARD)"
  [ -n "$(v PIBUZ_USER)" ] && conf_set AUDIO_USER "$(v PIBUZ_USER)"
  [ -n "$(v HA_WEBHOOK)" ] && conf_set HA_WEBHOOK "$(v HA_WEBHOOK)"
  if [ -n "$(v MA_URL)" ]; then
    conf_set MA_URL "$(v MA_URL)"; conf_set MA_TOKEN "$(v MA_TOKEN)"; conf_set MA_PLAYER "$(v MA_PLAYER)"
  fi
  if [ -f "$MANIFEST" ]; then
    v=$(sed -n 's/^room *= *"\(.*\)".*/\1/p' "$MANIFEST" | head -1);          [ -n "$v" ] && conf_set ROOM_NAME "$v"
    v=$(sed -n 's/^mode *= *"\(.*\)".*/\1/p' "$MANIFEST" | head -1);          [ -n "$v" ] && conf_set VOLUME_MODE "$v"
    v=$(sed -n 's/^mixer_control *= *"\([^"]*\)".*/\1/p' "$MANIFEST" | head -1); [ -n "$v" ] && conf_set MIXER_CONTROL "$v"
  fi
  unit() { systemctl cat "$1" >/dev/null 2>&1 && echo y || echo n; }
  conf_set WANT_QOBUZ "$(unit pibuz)"
  conf_set WANT_SPOTIFY "$(unit spotifyd)"
  conf_set WANT_AIRPLAY "$(unit shairport-sync)"
  conf_set WANT_MA "$(unit sendspin)"
  v=$(systemctl cat sendspin 2>/dev/null | sed -n 's/^ExecStart=.* --id \([^ ]*\).*/\1/p' | tr -d '"')
  [ -n "$v" ] && conf_set SENDSPIN_ID "$v"
  [ -n "${WANT_CAMILLADSP:-}" ] || { conf_set WANT_CAMILLADSP n; conf_set OUTPUT_ENGINE direct; conf_set OUTPUT_RATE native; }
  # A drop-in that sets ExecStart would keep overriding the units written
  # below: move it aside (its settings are taken over above)
  local u d
  for u in sendspin pibuz spotifyd shairport-sync player-guard now-playing playerui player-guard-helper; do
    for d in /etc/systemd/system/$u.service.d/*.conf; do
      [ -f "$d" ] && grep -q '^ExecStart=' "$d" || continue
      run mv "$d" "$d.before-homeaudio"
      info "moved aside $d (kept as .before-homeaudio)"
    done
  done
  info "room \"${ROOM_NAME:-?}\", DAC ${DAC_CARD:-?}, volume '${MIXER_CONTROL:-none}' (${VOLUME_MODE:-?})"
  info "sources: qobuz=$WANT_QOBUZ spotify=$WANT_SPOTIFY airplay=$WANT_AIRPLAY music-assistant=$WANT_MA${SENDSPIN_ID:+ (sendspin id $SENDSPIN_ID)}"
  unset -f v unit
}

# ---------------------------------------------------------------- questions

# The room's name: this machine's own hostname, or a custom one. Never taken
# from another Pi's answers, so a copied install.conf can't rename this room.
room_pick_name() {
  local host; host=$(uname -n)
  if [ -n "${ROOM_NAME:-}" ] && [ -z "$RECONFIGURE" ]; then
    remembered "Room name" "$ROOM_NAME"; return 0
  fi
  if [ -n "$ASSUME_YES" ] || [ ! -t 0 ]; then
    conf_set ROOM_NAME "${host^}"; return 0
  fi
  local choice custom
  info "Room name (shown in the apps):"
  info "  1) ${host^}  - this machine's hostname"
  info "  2) a custom name"
  read -r -p "    Choose 1 or 2 [1]: " choice
  case "${choice:-1}" in
    1) conf_set ROOM_NAME "${host^}" ;;
    2) read -r -p "    Custom room name: " custom
       [ -n "$custom" ] || die "no room name given"
       conf_set ROOM_NAME "$custom" ;;
    *) die "answer 1 or 2" ;;
  esac
}

room_questions() {
  say "About this room"
  ask AUDIO_USER "User the audio services run as" "${SUDO_USER:-pi}"
  id "$AUDIO_USER" >/dev/null 2>&1 || die "user '$AUDIO_USER' does not exist"
  room_pick_name

  room_pick_dac
  room_pick_mixer

  say "Output"
  info "No conversion by default: every source straight on the DAC, at the music's own rate."
  info "A studio (a DAC into an audio interface at a fixed 44.1 or 48 kHz) wants a"
  info "sample-rate converter: CamillaDSP, switched live in the web page."
  ask_yesno WANT_CAMILLADSP "Sample-rate converter (CamillaDSP): meters, and a fixed rate if you want one" n
  if [ "$WANT_CAMILLADSP" = y ]; then
    conf_set OUTPUT_ENGINE camilladsp
    # Fixed-clock gear (S/PDIF into a DAC or interface) needs one rate; the rest play at the music's own rate
    ask_yesno WANT_FIXED "Fixed sample rate (for fixed-clock gear)" "$([ "${OUTPUT_RATE:-native}" = native ] && echo n || echo y)"
    if [ "$WANT_FIXED" = y ]; then
      out_probe_rates || true    # the DAC idle: its rates are read now
      info "the DAC supports: $(out_dac_rates)"
      ask OUTPUT_RATE "Fixed rate in Hz" "${OUTPUT_RATE:-44100}"
      case " $(out_dac_rates) " in *" $OUTPUT_RATE "*) ;; *) warn "$OUTPUT_RATE Hz is not in the DAC's list: check it in the web page" ;; esac
      conf_set OUTPUT_RATE "$OUTPUT_RATE"
    else
      conf_set OUTPUT_RATE native
    fi
  else
    conf_set OUTPUT_ENGINE direct; conf_set OUTPUT_RATE native
  fi

  say "Sources - which apps can play in this room?"
  ask_yesno WANT_QOBUZ   "Qobuz Connect (Qobuz app)" y
  ask_yesno WANT_SPOTIFY "Spotify Connect (needs Spotify Premium)" y
  ask_yesno WANT_AIRPLAY "AirPlay 2 (Apple devices; builds from source, ~10 min)" y
  # Music Assistant: yes by default when it's on the network already
  local ma_default=n
  if [ -z "${WANT_MA:-}" ] || [ -n "$RECONFIGURE" ]; then
    . "$HOMEAUDIO/lib/sources/ma.sh"
    info "looking for Music Assistant on the network..."
    MA_FOUND=$(ma_discover)
    if [ -n "$MA_FOUND" ]; then info "found Music Assistant at $MA_FOUND"; ma_default=y
    else info "no Music Assistant found (fine if you don't use it)"; fi
  fi
  ask_yesno WANT_MA      "Music Assistant (only if you already run it somewhere)" $ma_default

  say "Home Assistant (optional)"
  info "now-playing can push what plays to a Home Assistant webhook."
  ask HA_WEBHOOK "Webhook URL, e.g. http://homeassistant.local:8123/api/webhook/<id> (empty: none)" ""
}

room_pick_dac() {
  local cards n guess
  cards=$(dac_list | grep -viE '\|.*(hdmi|headphones)' || true)
  if [ -z "$cards" ]; then
    room_offer_overlay   # exits: a HAT needs a reboot before it shows up
  fi
  n=$(printf '%s\n' "$cards" | wc -l)
  guess=$(dac_guess)
  if [ "$n" -gt 1 ]; then
    info "More than one sound card:"
    # shellcheck disable=SC2046
    ask_choice DAC_CARD "Which one plays the music?" "$guess" $(printf '%s\n' "$cards" | cut -d'|' -f1)
  else
    conf_set DAC_CARD "${DAC_CARD:-$guess}"
  fi
  [ -e "/proc/asound/$DAC_CARD" ] || die "sound card '$DAC_CARD' not found:$(printf '\n%s' "$(cat /proc/asound/cards)")"
  info "DAC: $DAC_CARD ($(dac_list | grep "^$DAC_CARD|" | cut -d'|' -f2))"
}

# No DAC yet: a HAT needs its overlay in config.txt (USB DACs just work)
room_offer_overlay() {
  local cfg=/boot/firmware/config.txt
  say "No sound card found for music"
  info "A USB DAC just needs plugging in (then run this again)."
  info "A HAT (board on the Pi's pins) needs to be enabled first:"
  ask_choice DAC_OVERLAY "Which HAT? (or 'none' for USB)" none \
    none hifiberry-dac hifiberry-dacplus hifiberry-digi hifiberry-digi-pro \
    allo-digione iqaudio-dacplus justboom-dac justboom-digi
  [ "$DAC_OVERLAY" = none ] && die "plug in the USB DAC, then run this again"
  if ! grep -q "^dtoverlay=$DAC_OVERLAY\b" "$cfg"; then
    run sed -i -e 's/^dtparam=audio=on/#dtparam=audio=on/' "$cfg"
    printf '\n# homeaudio: DAC HAT\ndtoverlay=%s\n' "$DAC_OVERLAY" | { [ -n "$DRY_RUN" ] && cat || tee -a "$cfg" >/dev/null; }
  fi
  say "Enabled $DAC_OVERLAY in $cfg"
  info "Reboot, then run the same command again:  sudo reboot"
  exit 0
}

room_pick_mixer() {
  local mixers n guess
  mixers=$(dac_mixers "$DAC_CARD")
  if [ -z "$mixers" ]; then
    conf_set MIXER_CONTROL ""
    info "No hardware volume on this DAC (normal for S/PDIF): every source keeps"
    info "its own volume slider. Set the level on your amplifier."
    return 0
  fi
  n=$(printf '%s\n' "$mixers" | wc -l)
  guess=$(dac_mixer_guess "$DAC_CARD")
  if [ "$n" -gt 1 ]; then
    local IFS=$'\n'
    # shellcheck disable=SC2046
    ask_choice MIXER_CONTROL "Which control is the volume?" "$guess" $(printf '%s\n' "$mixers")
  else
    [ -n "${MIXER_CONTROL:-}" ] || conf_set MIXER_CONTROL "$guess"
  fi
  info "Hardware volume: '$MIXER_CONTROL'"
  info "All sources share it: \"shared\" keeps the level when the app changes,"
  info "\"per_source\" gives each app back its own last level."
  ask_choice VOLUME_MODE "Volume mode" shared shared per_source
}

# ---------------------------------------------------------------- base

room_base() {
  say "Base packages, groups, settings"
  run apt-get update -qq
  apt_install inotify-tools curl jq alsa-utils psmisc python3 dbus ca-certificates avahi-daemon avahi-utils
  run groupadd -f audioguard
  run usermod -aG audio,audioguard "$AUDIO_USER"
  id playerui >/dev/null 2>&1 || run useradd --system --no-create-home --shell /usr/sbin/nologin playerui
  run usermod -aG audioguard playerui
  echo 'd /run/player-guard 0777 root root -' | write_file /etc/tmpfiles.d/player-guard.conf
  run systemd-tmpfiles --create /etc/tmpfiles.d/player-guard.conf
  room_env
}

# /etc/player-guard.env: everything the runtime scripts read. Secrets live here.
room_env() {
  {
    echo "USB_CARD=$DAC_CARD"
    echo "PIBUZ_USER=$AUDIO_USER"
    [ "${WANT_QOBUZ:-n}" = y ] && echo "PIBUZ_UNIT=pibuz"
    if [ "${WANT_MA:-n}" = y ]; then
      echo "MA_URL=${MA_URL:-}"
      echo "MA_TOKEN=${MA_TOKEN:-}"
      echo "MA_PLAYER=${MA_PLAYER:-}"
    fi
    [ -n "${HA_WEBHOOK:-}" ] && echo "HA_WEBHOOK=$HA_WEBHOOK"
    true
  } | write_file "$ENV_FILE" 640
  run chgrp audioguard "$ENV_FILE"
}

# ---------------------------------------------------------------- player-guard

room_guard() {
  say "player-guard: one source at a time"
  local f
  for f in player-guard qobuz-hook spotify-hook airplay-start airplay-stop now-playing; do
    run install -m 755 "$HOMEAUDIO/pi/bin/$f" "/usr/local/bin/$f"
  done
  write_file /etc/systemd/system/player-guard.service <<'EOF'
[Unit]
Description=Player guard: one source at a time
After=sound.target

[Service]
ExecStart=/usr/local/bin/player-guard
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------------------------------------- playerui

room_webui() {
  say "playerui (web page) and player-guard-helper"
  local b
  for b in playerui player-guard-helper; do
    fetch_binary "$b" "/usr/local/bin/$b" || room_build_webui
  done
  run install -m 644 "$HOMEAUDIO/webui/playerui/systemd/playerui.service" /etc/systemd/system/
  # Announce this room on the network: every room's page finds the others
  write_file /etc/avahi/services/homeaudio.service <<EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">homeaudio %h</name>
  <service>
    <type>_homeaudio._tcp</type>
    <port>8189</port>
    <txt-record>room=$ROOM_NAME</txt-record>
  </service>
</service-group>
EOF
  run install -m 644 "$HOMEAUDIO/webui/helper/systemd/player-guard-helper.service" /etc/systemd/system/
}

# Download a prebuilt aarch64 binary from the latest release, checksum-verified
fetch_binary() {
  local name=$1 dest=$2 tmp
  [ -n "${BUILD:-}" ] && return 1
  tmp=$(mktemp -d)
  if fetch_asset "$name-linux-aarch64" "$tmp/$name" &&
     fetch_asset "$name-linux-aarch64.sha256" "$tmp/$name.sha256" &&
     (cd "$tmp" && sed "s#  .*#  $name#" "$name.sha256" | sha256sum -c --quiet); then
    run install -m 755 "$tmp/$name" "$dest"
    info "$name: downloaded"
    rm -rf "$tmp"; return 0
  fi
  rm -rf "$tmp"
  warn "$name: no prebuilt download ($RELEASE_URL)"
  return 1
}

# fetch_asset <name> <file>: one file from the latest release. A private repo
# (while testing) needs a login: then it goes through gh, as the user running
# sudo, who logged in with `gh auth login`.
fetch_asset() {
  curl -fsL "$RELEASE_URL/$1" -o "$2" && return 0
  if [ -z "${HOMEAUDIO_RELEASE_URL:-}" ] && [ -n "${SUDO_USER:-}" ] && command -v gh >/dev/null; then
    sudo -u "$SUDO_USER" gh release download --repo "${REPO_URL#https://github.com/}" \
      --pattern "$1" --output - > "$2" 2>/dev/null && [ -s "$2" ] && return 0
  fi
  return 1
}

# Fallback: build playerui + helper on the Pi (Rust, ~15 min on a Pi 4)
room_build_webui() {
  [ -n "${WEBUI_BUILT:-}" ] && return 0
  info "building playerui and player-guard-helper from source"
  apt_install build-essential pkg-config
  run sudo -u "$AUDIO_USER" sh -c 'command -v cargo >/dev/null || [ -x "$HOME/.cargo/bin/cargo" ] || curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal'
  local tdir; tdir=$(getent passwd "$AUDIO_USER" | cut -d: -f6)/.cache/homeaudio-build
  run sudo -u "$AUDIO_USER" sh -c "cd '$HOMEAUDIO/webui' && CARGO_TARGET_DIR='$tdir' \$HOME/.cargo/bin/cargo build --release -p playerui -p player-guard-helper"
  run install -m 755 "$tdir/release/playerui" "$tdir/release/player-guard-helper" /usr/local/bin/
  WEBUI_BUILT=1
}

# ---------------------------------------------------------------- now-playing

room_nowplaying() {
  write_file /etc/systemd/system/now-playing.service <<'EOF'
[Unit]
Description=Now playing on this room's DAC (playerui, and Home Assistant if configured)
After=network-online.target player-guard.service

[Service]
ExecStart=/usr/local/bin/now-playing
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------------------------------------- manifest

# /etc/player-guard-services.toml, from the answers and what is installed.
# Rewritten on every run; the [[service]] list follows the installed sources.
# Other rooms need no listing: playerui finds them on the network
# (_homeaudio._tcp); OTHER_ROOMS in install.conf can add ones it can't see.
room_manifest() {
  local rooms url self
  self="http://$(uname -n).local:8189"
  rooms="\"$self\""
  for url in ${OTHER_ROOMS:-}; do rooms="$rooms, \"$url\""; done
  {
    cat <<EOF
# Written by install.sh - re-run it to change these (answers: $CONF).
room = "$ROOM_NAME"
audio_owner_file = "/run/player-guard/audio-owner"
now_playing_file = "/run/player-guard/now-playing.json"
helper_socket = "/run/player-guard/helper.sock"
rooms = [$rooms]

[music_assistant]
env_file = "$ENV_FILE"
EOF
    [ "${WANT_QOBUZ:-n}" = y ]   && room_service pibuz "Qobuz Connect" pibuz
    [ "${WANT_SPOTIFY:-n}" = y ] && room_service spotifyd "Spotify Connect" spotifyd
    [ "${WANT_AIRPLAY:-n}" = y ] && room_service shairport-sync "AirPlay 2" shairport-sync
    printf '\n[[service]]\nid = "player-guard"\nname = "Player guard"\nunit = "player-guard"\ntoggleable = false\n'
    cat <<EOF

# "Add a source" in playerui runs these (they call install.sh add <source>)
[jobs]
add_qobuz = "$HOMEAUDIO/pi/jobs/add-qobuz.sh"
add_spotify = "$HOMEAUDIO/pi/jobs/add-spotify.sh"
add_airplay2 = "$HOMEAUDIO/pi/jobs/add-airplay.sh"
add_ma = "$HOMEAUDIO/pi/jobs/add-ma.sh"
set_rate = "$HOMEAUDIO/pi/jobs/set-rate.sh"

# Output: "native" = no conversion, or a fixed rate every source is converted to.
# engine "camilladsp" switches live; "direct" = sources straight on the DAC
[output]
rate = "${OUTPUT_RATE:-native}"
engine = "${OUTPUT_ENGINE:-camilladsp}"
EOF
    if [ -n "${MIXER_CONTROL:-}" ]; then
      cat <<EOF

[volume]
mode = "${VOLUME_MODE:-shared}"
mixer_card = "hw:CARD=$DAC_CARD"
mixer_control = "$MIXER_CONTROL"
EOF
      if [ "${WANT_QOBUZ:-n}" = y ]; then
        printf 'software_sources = ["qobuz"]\nsoftware_sources_follow = true\n'
      fi
    fi
  } | write_file "$MANIFEST"
}

room_service() {
  printf '\n[[service]]\nid = "%s"\nname = "%s"\nunit = "%s"\ntoggleable = true\n' "$1" "$2" "$3"
}

# ---------------------------------------------------------------- start

room_start() {
  say "Starting"
  run systemctl daemon-reload
  local u
  out_cdsp && run systemctl enable homeaudio-meter-chain >/dev/null 2>&1 || true
  for u in player-guard player-guard-helper playerui now-playing; do
    run systemctl enable "$u" >/dev/null 2>&1 || true
  done
  out_cdsp && run systemctl restart homeaudio-meter-chain
  run systemctl restart player-guard now-playing
  out_probe_rates || true    # the DAC's rates, while it's idle
  if [ -n "${HOMEAUDIO_JOB:-}" ]; then
    # Run from playerui's "Add a source": restarting the helper now would
    # kill this very job. It re-reads the manifest after the job, in 10 s.
    run systemd-run --quiet --on-active=10 --unit="homeaudio-restart-$$" \
      systemctl restart player-guard-helper playerui
    info "the web page reloads in a few seconds"
  else
    run systemctl restart player-guard-helper playerui
  fi
}

room_summary() {
  [ -n "$DRY_RUN" ] && return 0
  sleep 2
  say "Done - $ROOM_NAME"
  local u
  for u in player-guard player-guard-helper playerui now-playing sendspin pibuz spotifyd shairport-sync; do
    systemctl cat "$u" >/dev/null 2>&1 && printf '    %-20s %s\n' "$u" "$(systemctl is-active "$u")"
  done
  info ""
  info "Web page: http://$(uname -n).local:8189"
  info "Watch source changes: journalctl -u player-guard -f -o cat"
  [ "${WANT_QOBUZ:-n}" = y ] && info "Qobuz: pick \"$ROOM_NAME\" in the Qobuz app once, from then on it stays connected."
  return 0
}

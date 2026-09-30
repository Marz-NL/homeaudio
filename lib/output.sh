# Output rate: bit-perfect (every source straight on the DAC, at the music's
# own rate) or one fixed rate for everything - for a DAC feeding gear that
# runs at a fixed clock, like an audio interface's S/PDIF input in a studio.
# Fixed: an ALSA device "homeaudio" converts with libsamplerate at its best
# quality, and every source plays through it. Sourced, not run.

OUT_PCM=homeaudio
OUT_CONF=/etc/alsa/conf.d/60-homeaudio.conf
OUT_RATES="native 44100 48000"

out_fixed() { [ "${OUTPUT_RATE:-native}" != native ]; }

# The ALSA device the sources play on
out_device() {
  if out_fixed; then echo "$OUT_PCM"; else echo "hw:CARD=$DAC_CARD,DEV=0"; fi
}

# In words, for messages and the web page
out_label() {
  case "${OUTPUT_RATE:-native}" in
    native) echo "bit-perfect" ;;
    44100)  echo "fixed 44.1 kHz" ;;
    48000)  echo "fixed 48 kHz" ;;
    *)      echo "${OUTPUT_RATE}" ;;
  esac
}

# Write (fixed) or remove (bit-perfect) the converting ALSA device
out_write_alsa_conf() {
  if ! out_fixed; then
    [ -e "$OUT_CONF" ] && run rm -f "$OUT_CONF"
    return 0
  fi
  apt_install libasound2-plugins   # the libsamplerate converter for ALSA
  write_file "$OUT_CONF" <<EOF
# Written by homeaudio's install.sh: every source plays through this at a
# fixed rate ($(out_label)). Switch in the web page, or: install.sh rate native
pcm.$OUT_PCM {
    type plug
    slave {
        pcm "hw:CARD=$DAC_CARD,DEV=0"
        rate $OUTPUT_RATE
    }
    rate_converter "samplerate_best"
    hint {
        show on
        description "homeaudio: $(out_label) on $DAC_CARD"
    }
}
EOF
}

# `install.sh rate <native|44100|48000>`: switch, and move the installed
# sources over. They all restart: spotifyd and sendspin reconnect by
# themselves; Qobuz (pibuz) and AirPlay have to be picked again in their app.
out_set_rate() {
  local rate=$1 src
  need_root rate "$rate"
  case " $OUT_RATES " in *" $rate "*) ;; *) die "rate must be one of: $OUT_RATES" ;; esac
  [ -n "${DAC_CARD:-}" ] || die "no room set up yet - run: sudo ./install.sh room"
  # What was playing, to pick it up again afterwards
  local playing=""
  if grep -q RUNNING "/proc/asound/$DAC_CARD/pcm0p/sub0/status" 2>/dev/null; then
    playing=$(cat /run/player-guard/audio-owner 2>/dev/null || true)
  fi
  conf_set OUTPUT_RATE "$rate"
  say "Output: $(out_label)"
  out_write_alsa_conf
  for src in qobuz spotify airplay ma; do
    local want=WANT_${src^^}
    [ "${!want:-n}" = y ] || continue
    . "$HOMEAUDIO/lib/sources/$src.sh"
    "src_${src}_output"
  done
  room_manifest
  run systemctl restart player-guard
  info "all sources now play $(out_label)"
  [ -n "$playing" ] && [ -z "$DRY_RUN" ] && out_resume "$playing"
  return 0
}

# Ask the source that was playing before a switch to continue. Waits for it
# to be back (a restarted one reconnects first), gives up quietly after ~20 s.
out_resume() {
  local src=$1 i
  local user; user=$(sed -n 's/^PIBUZ_USER=//p' /etc/player-guard.env 2>/dev/null)
  case "$src" in
    qobuz)
      info "Qobuz: pick \"${ROOM_NAME:-this room}\" in the Qobuz app again to continue" ;;
    ma)
      for i in $(seq 1 20); do
        systemctl is-active -q sendspin && journalctl -u sendspin --since "-30 s" -o cat | grep -q "Server connected" && break
        sleep 1
      done
      /usr/local/bin/ma-play && info "Music Assistant: asked to play again" ;;
    spotify)
      local pid=""
      for i in $(seq 1 20); do pid=$(pidof spotifyd) && dbus-send --system --print-reply \
        --dest="org.mpris.MediaPlayer2.spotifyd.instance$pid" /org/mpris/MediaPlayer2 \
        org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1 && break; sleep 1; done
      if [ -n "$pid" ] && dbus-send --system --print-reply --dest="org.mpris.MediaPlayer2.spotifyd.instance$pid" \
           /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player.Play >/dev/null 2>&1; then
        info "Spotify: asked to play again (if it doesn't, press play in the app)"
      else
        info "Spotify: press play in the app to continue"
      fi ;;
    airplay)
      info "AirPlay: pick the room again on your iPhone/Mac to continue" ;;
  esac
  return 0
}

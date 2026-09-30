# Output rate. Two ways out of a room:
#   direct      every source straight on the DAC, at the music's own rate
#               (bit-perfect, the default)
#   camilladsp  every source plays into CamillaDSP, which feeds the DAC: at
#               the music's own rate (bit-perfect, passed through untouched)
#               or converted to one fixed rate - for a DAC feeding gear that
#               runs at a fixed clock, like an audio interface's S/PDIF input
#               in a studio. Switching between those is live: CamillaDSP
#               reloads, nothing restarts, the music keeps playing.
# The first fixed rate moves a room to camilladsp (the sources restart once);
# `install.sh rate direct` moves it back. Sourced, not run.

OUT_PCM=homeaudio                          # the ALSA device the sources play on
OUT_CONF=/etc/alsa/conf.d/60-homeaudio.conf
OUT_RATES="native 44100 48000 direct"
OUT_TARGET=/etc/homeaudio/output-rate       # native | 44100 | 48000, read per stream
OUT_RUN=/run/homeaudio-cdsp                 # the stream's format and CamillaDSP's config
OUT_GEN=/usr/local/lib/homeaudio/cdsp-config
CAMILLADSP_VERSION=v4.1.3
ALSA_CDSP_COMMIT=1a1b0a3e452f87372881ffaa9391a11d0ff6d541   # github.com/scripple/alsa_cdsp
ALSA_CDSP_SO=/usr/lib/$(uname -m)-linux-gnu/alsa-lib/libasound_module_pcm_cdsp.so

out_cdsp()  { [ "${OUTPUT_ENGINE:-direct}" = camilladsp ]; }
out_fixed() { [ "${OUTPUT_RATE:-native}" != native ]; }

# The ALSA device the sources play on
out_device() {
  if out_cdsp; then echo "$OUT_PCM"; else echo "hw:CARD=$DAC_CARD,DEV=0"; fi
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

# Install CamillaDSP and the ALSA plugin that starts it per stream, and write
# the "homeaudio" device (camilladsp), or remove it all from ALSA (direct)
out_write_alsa_conf() {
  if ! out_cdsp; then
    [ -e "$OUT_CONF" ] && run rm -f "$OUT_CONF"
    return 0
  fi
  out_install_camilladsp
  run mkdir -p "$(dirname "$OUT_TARGET")"
  echo "${OUTPUT_RATE:-native}" | write_file "$OUT_TARGET"
  run chmod 644 "$OUT_TARGET"
  # Every source user writes here (they're all in the audio group)
  echo "d $OUT_RUN 2775 root audio -" | write_file /etc/tmpfiles.d/homeaudio-cdsp.conf
  run systemd-tmpfiles --create /etc/tmpfiles.d/homeaudio-cdsp.conf
  out_write_generator
  write_file "$OUT_CONF" <<EOF
# Written by homeaudio's install.sh: every source plays into CamillaDSP, which
# feeds the DAC. The rate is in $OUT_TARGET; switch in the web page,
# or: install.sh rate <native|44100|48000>. Back to direct: install.sh rate direct
pcm.${OUT_PCM}_cdsp {
    type cdsp
    cpath "/usr/local/bin/camilladsp"
    config_cmd "$OUT_GEN"
    config_out "$OUT_RUN/config.yml"
    channels 2
    rates = [ 44100 48000 88200 96000 176400 192000 352800 384000 ]
    cargs [ -o "$OUT_RUN/camilladsp.log" ]
}
# The name the sources use. A pass-through, only so it can carry a hint:
# PortAudio (Music Assistant's sendspin) lists devices by their hint, and the
# cdsp plugin itself refuses one.
pcm.$OUT_PCM {
    type asym
    playback.pcm "${OUT_PCM}_cdsp"
    hint {
        show on
        description "homeaudio: CamillaDSP on $DAC_CARD"
    }
}
EOF
}

out_install_camilladsp() {
  local arch tmp
  if [ "$(/usr/local/bin/camilladsp --version 2>/dev/null | awk '{print "v"$2}')" != "$CAMILLADSP_VERSION" ]; then
    arch=$(uname -m)
    case "$arch" in aarch64|x86_64) ;; *) die "CamillaDSP: no download for $arch (a 64-bit OS is needed)" ;; esac
    tmp=$(mktemp -d)
    run curl -fsSL -o "$tmp/cdsp.tgz" \
      "https://github.com/HEnquist/camilladsp/releases/download/$CAMILLADSP_VERSION/camilladsp-linux-$arch.tar.gz" \
      || die "CamillaDSP: download failed"
    run tar -xzf "$tmp/cdsp.tgz" -C "$tmp"
    run install -m 755 "$tmp/camilladsp" /usr/local/bin/camilladsp
    rm -rf "$tmp"
    info "CamillaDSP $CAMILLADSP_VERSION installed"
  fi
  [ -f "$ALSA_CDSP_SO" ] && return 0
  tmp=$(mktemp -d)
  if fetch_asset "libasound_module_pcm_cdsp-linux-$(uname -m).so" "$tmp/cdsp.so"; then
    run install -D -m 644 "$tmp/cdsp.so" "$ALSA_CDSP_SO"
    info "ALSA CamillaDSP plugin: downloaded"
  else
    info "ALSA CamillaDSP plugin: building (a minute)"
    apt_install build-essential libasound2-dev git
    run git clone -q https://github.com/scripple/alsa_cdsp "$tmp/src"
    run git -C "$tmp/src" checkout -q "$ALSA_CDSP_COMMIT"
    run make -s -C "$tmp/src"
    run install -D -m 644 "$tmp/src/libasound_module_pcm_cdsp.so" "$ALSA_CDSP_SO"
  fi
  rm -rf "$tmp"
}

# The CamillaDSP config, written per stream by the plugin (as the source's
# user), and again by `--reload` for a live switch
out_write_generator() {
  run mkdir -p "$(dirname "$OUT_GEN")"
  write_file "$OUT_GEN" <<'GEN'
#!/bin/sh
# homeaudio: writes CamillaDSP's config for one stream.
#   cdsp-config <format> <rate> <channels>   called by the ALSA plugin per stream
#   cdsp-config --reload                     rate changed: rewrite, CamillaDSP reloads live
umask 002
RUN=/run/homeaudio-cdsp
if [ "$1" = --reload ]; then
  reload=1
  [ -f $RUN/stream ] || exit 0          # nothing played yet
  set -- $(cat $RUN/stream)
else
  reload=
  echo "$1 $2 $3" > $RUN/stream
  # CamillaDSP creates its log as this stream's user; another source's user
  # can't append to it, but may replace it (the directory is the audio group's)
  [ ! -e $RUN/camilladsp.log ] || [ -w $RUN/camilladsp.log ] || rm -f $RUN/camilladsp.log
fi
# The plugin's format names -> CamillaDSP's
case "$1" in
  S16LE) fmt=S16_LE ;; S24LE) fmt=S24_4_RJ_LE ;; S24LE3) fmt=S24_3_LE ;;
  S32LE) fmt=S32_LE ;; FLOAT32LE) fmt=F32_LE ;; FLOAT64LE) fmt=F64_LE ;; *) fmt=$1 ;;
esac
target=$(cat /etc/homeaudio/output-rate 2>/dev/null || echo native)
if [ "$target" = native ] || [ "$target" = "$2" ]; then
  # bit-perfect: the stream's own rate, samples passed through untouched
  out=$2 convert=
else
  # converted; 1 dB headroom, as resampling can overshoot near full scale
  out=$target convert=1
fi
DAC=$(sed -n 's/^USB_CARD=//p' /etc/homeaudio/cdsp-dac)
{
  cat <<EOF
devices:
  samplerate: $out
  chunksize: 1024
  queuelimit: 1
  capture_samplerate: $2
EOF
  if [ -n "$convert" ]; then cat <<EOF
  resampler:
    type: Synchronous
EOF
  fi
  cat <<EOF
  capture:
    type: Stdin
    channels: $3
    format: $fmt
  playback:
    type: Alsa
    channels: $3
    device: "hw:CARD=$DAC,DEV=0"
EOF
  if [ -n "$convert" ]; then cat <<EOF
filters:
  headroom:
    type: Gain
    parameters:
      gain: -1.0
pipeline:
  - type: Filter
    channels: [0, 1]
    names: [headroom]
EOF
  fi
} > $RUN/config.yml.new && mv -f $RUN/config.yml.new $RUN/config.yml
[ -n "$reload" ] && pkill -HUP -x camilladsp
exit 0
GEN
  run chmod 755 "$OUT_GEN"
  # the DAC, readable by every source user (player-guard.env is not)
  echo "USB_CARD=$DAC_CARD" | write_file /etc/homeaudio/cdsp-dac
  run chmod 644 /etc/homeaudio/cdsp-dac
}

# `install.sh rate <native|44100|48000|direct>`
out_set_rate() {
  local rate=$1 src
  need_root rate "$rate"
  case " $OUT_RATES " in *" $rate "*) ;; *) die "rate must be one of: $OUT_RATES" ;; esac
  [ -n "${DAC_CARD:-}" ] || die "no room set up yet - run: sudo ./install.sh room"

  # Already on CamillaDSP: live, nothing restarts
  if out_cdsp && [ "$rate" != direct ]; then
    conf_set OUTPUT_RATE "$rate"
    echo "$rate" | write_file "$OUT_TARGET"
    run "$OUT_GEN" --reload
    room_manifest
    say "Output: $(out_label) (switched live)"
    return 0
  fi
  # direct -> direct: nothing to do
  if ! out_cdsp && { [ "$rate" = direct ] || [ "$rate" = native ]; }; then
    conf_set OUTPUT_RATE native
    say "Output: bit-perfect, straight on the DAC (already)"
    return 0
  fi

  # Moving between direct and CamillaDSP: every source reopens the DAC once
  local playing=""
  if grep -q RUNNING "/proc/asound/$DAC_CARD/pcm0p/sub0/status" 2>/dev/null; then
    playing=$(cat /run/player-guard/audio-owner 2>/dev/null || true)
  fi
  if [ "$rate" = direct ]; then
    conf_set OUTPUT_ENGINE direct; conf_set OUTPUT_RATE native; conf_set WANT_CAMILLADSP n
    say "Output: bit-perfect, straight on the DAC (CamillaDSP off)"
  else
    conf_set OUTPUT_ENGINE camilladsp; conf_set OUTPUT_RATE "$rate"; conf_set WANT_CAMILLADSP y
    say "Output: $(out_label), through CamillaDSP - from now on switching is live"
  fi
  out_write_alsa_conf
  for src in qobuz spotify airplay ma; do
    local want=WANT_${src^^}
    [ "${!want:-n}" = y ] || continue
    . "$HOMEAUDIO/lib/sources/$src.sh"
    "src_${src}_output"
  done
  room_manifest
  run systemctl restart player-guard
  info "all sources moved over (they restarted once)"
  [ -n "$playing" ] && [ -z "$DRY_RUN" ] && out_resume "$playing"
  return 0
}

# Ask the source that was playing before a move to continue. Waits for it
# to be back (a restarted one reconnects first), gives up quietly after ~20 s.
out_resume() {
  local src=$1 i
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

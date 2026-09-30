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
# sources over. pibuz switches without a restart (its Qobuz session stays);
# spotifyd, shairport-sync and sendspin restart and reconnect.
out_set_rate() {
  local rate=$1 src
  need_root rate "$rate"
  case " $OUT_RATES " in *" $rate "*) ;; *) die "rate must be one of: $OUT_RATES" ;; esac
  [ -n "${DAC_CARD:-}" ] || die "no room set up yet - run: sudo ./install.sh room"
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
}

# Source: Qobuz Connect, via pibuz (https://github.com/PhilipVinc/pibuz).
# pibuz has only its own (software) volume: player-guard puts the hardware
# mixer at the top while it plays ([volume] software_sources).

PIBUZ_REPO=https://github.com/PhilipVinc/pibuz
# pibuz publishes no binaries: this project's release builds this commit,
# unchanged. 2.6.0 has no tag yet; its last commit fixes a track from the
# cache starting at 0:00 when handed over mid-way.
PIBUZ_VERSION=2.6.0
PIBUZ_COMMIT=8184ba3c491bf6ccbecc4c138f0a20ae3bb3d212

src_qobuz_questions() { :; }

src_qobuz_install() {
  say "Qobuz Connect (pibuz)"
  local have upgraded=
  have=$(/usr/local/bin/pibuz --version 2>/dev/null | awk 'NR == 1 {print $2}')
  if [ "$have" = "$PIBUZ_VERSION" ] && [ -z "${BUILD:-}" ]; then
    info "already installed: pibuz $have"
  else
    [ -n "$have" ] && info "pibuz $have -> $PIBUZ_VERSION"
    fetch_binary pibuz /usr/local/bin/pibuz || qobuz_build
    [ -n "$have" ] && upgraded=1
  fi

  write_file /etc/systemd/system/pibuz.service <<EOF
[Unit]
Description=Qobuz Connect (pibuz)
After=network-online.target sound.target
Wants=network-online.target

[Service]
User=$AUDIO_USER
SupplementaryGroups=audio
ExecStart=/usr/local/bin/pibuz run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable pibuz >/dev/null 2>&1
  # Settings go through the running daemon. A restart would drop an open
  # Qobuz Connect session, so only start it when it isn't running.
  if [ -n "$upgraded" ] && systemctl is-active -q pibuz; then
    run systemctl restart pibuz
    info "pibuz restarted for the new version: pick \"$ROOM_NAME\" in the Qobuz app once more"
  fi
  systemctl is-active -q pibuz || run systemctl start pibuz
  qobuz_settings
}

# From source (30-60 min on a Pi 4) - with BUILD=1, or when there's no release
qobuz_build() {
  info "building pibuz from source (30-60 min on a Pi 4)"
  apt_install build-essential pkg-config git libasound2-dev libdbus-1-dev libssl-dev libjack-jackd2-dev
  run sudo -u "$AUDIO_USER" sh -c 'command -v cargo >/dev/null || [ -x "$HOME/.cargo/bin/cargo" ] || curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal'
  local src; src=$(getent passwd "$AUDIO_USER" | cut -d: -f6)/.cache/pibuz-src
  run rm -rf "$src"
  run sudo -u "$AUDIO_USER" git clone -q "$PIBUZ_REPO" "$src"
  run sudo -u "$AUDIO_USER" git -C "$src" checkout -q "$PIBUZ_COMMIT"
  run sudo -u "$AUDIO_USER" sh -c "cd '$src' && \$HOME/.cargo/bin/cargo build --release -p pibuz"
  run install -m 755 "$src/target/release/pibuz" /usr/local/bin/pibuz
}

qobuz_settings() {
  [ -n "$DRY_RUN" ] && { info "would configure pibuz for $(out_device), name \"$ROOM_NAME\""; return 0; }
  local i
  for i in $(seq 1 20); do sudo -u "$AUDIO_USER" pibuz ping >/dev/null 2>&1 && break; sleep 0.5; done
  qobuz_set audio.backend               alsa
  # hw also for the fixed-rate device: pibuz opens a bare ALSA name defined in
  # conf.d (homeaudio) directly; 'pcm' would go through CPAL, which can't find
  # it and falls back to the default card (the Pi's headphone jack)
  qobuz_set audio.alsa_plugin           hw
  qobuz_set audio.device                "$(out_device)"
  qobuz_set audio.alsa_hardware_volume  false
  qobuz_set audio.normalization_enabled false
  qobuz_set audio.volume_curve          perceptual   # an exponential taper the guard converts with (player-guard QCURVE)
  qobuz_set qconnect.device_name        "$ROOM_NAME"
  qobuz_set qconnect.startup_mode       on        # the room is in the Qobuz app from boot
  qobuz_set hooks.script                /usr/local/bin/qobuz-hook
}

# Output rate switched. pibuz only really moves to a new output device (or
# a changed ALSA definition) after a restart - its own "output reinitialized"
# keeps playing on the old one - so restart it. That ends the Qobuz Connect
# session: the room has to be picked in the Qobuz app again.
src_qobuz_output() {
  qobuz_settings
  run systemctl restart pibuz
}

qobuz_set() {
  local now
  now=$(sudo -u "$AUDIO_USER" pibuz settings show 2>/dev/null | awk -v k="$1" '$1 == k { $1 = $2 = ""; sub(/^ +/, ""); print }')
  [ "$now" = "$2" ] && return 0   # unchanged: don't make pibuz reopen the DAC
  if sudo -u "$AUDIO_USER" pibuz settings set "$1" "$2" >/dev/null 2>&1; then
    info "pibuz $1 = $2"
  else
    warn "could not set pibuz $1 - run 'pibuz setup' once to set it by hand"
  fi
}

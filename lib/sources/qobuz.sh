# Source: Qobuz Connect, via pibuz (https://github.com/PhilipVinc/pibuz).
# pibuz has only its own (software) volume: player-guard puts the hardware
# mixer at the top while it plays ([volume] software_sources).

PIBUZ_REPO=https://github.com/PhilipVinc/pibuz
# pibuz publishes no binaries: this project's release builds this tag, unchanged
PIBUZ_VERSION=v2.5.1

src_qobuz_questions() { :; }

src_qobuz_install() {
  say "Qobuz Connect (pibuz)"
  if [ -x /usr/local/bin/pibuz ] && [ -z "${BUILD:-}" ]; then
    info "already installed: $(/usr/local/bin/pibuz --version 2>/dev/null | head -1)"
  elif ! fetch_binary pibuz /usr/local/bin/pibuz && { [ -n "${BUILD:-}" ] || ! qobuz_install_release; }; then
    qobuz_build
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
  systemctl is-active -q pibuz || run systemctl start pibuz
  qobuz_settings
}

# pibuz's own release, should it ever ship pibuz-<version>-linux-aarch64.tar.gz
qobuz_install_release() {
  local tag ver dir tmp
  tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$PIBUZ_REPO/releases/latest" | sed 's#.*/tag/##')
  case "$tag" in v[0-9]*) ;; *) return 1 ;; esac
  ver=${tag#v}; dir="pibuz-$ver-linux-aarch64"; tmp=$(mktemp -d)
  if curl -fsL "$PIBUZ_REPO/releases/download/$tag/$dir.tar.gz" -o "$tmp/$dir.tar.gz" &&
     curl -fsL "$PIBUZ_REPO/releases/download/$tag/$dir.tar.gz.sha256" -o "$tmp/$dir.tar.gz.sha256" &&
     (cd "$tmp" && sha256sum -c --quiet "$dir.tar.gz.sha256") &&
     tar -xzf "$tmp/$dir.tar.gz" -C "$tmp"; then
    run install -m 755 "$tmp/$dir/pibuz" /usr/local/bin/pibuz
    rm -rf "$tmp"; return 0
  fi
  rm -rf "$tmp"; return 1
}

# From source (30-60 min on a Pi 4) - with BUILD=1, or when there's no release
qobuz_build() {
  info "building pibuz from source (30-60 min on a Pi 4)"
  run apt-get install -y -qq build-essential pkg-config git libasound2-dev libdbus-1-dev libssl-dev libjack-jackd2-dev
  run sudo -u "$AUDIO_USER" sh -c 'command -v cargo >/dev/null || [ -x "$HOME/.cargo/bin/cargo" ] || curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal'
  local src; src=$(getent passwd "$AUDIO_USER" | cut -d: -f6)/.cache/pibuz-src
  run rm -rf "$src"
  run sudo -u "$AUDIO_USER" git clone -q --depth 1 --branch "$PIBUZ_VERSION" "$PIBUZ_REPO" "$src"
  run sudo -u "$AUDIO_USER" sh -c "cd '$src' && \$HOME/.cargo/bin/cargo build --release -p pibuz"
  run install -m 755 "$src/target/release/pibuz" /usr/local/bin/pibuz
}

qobuz_settings() {
  [ -n "$DRY_RUN" ] && { info "would configure pibuz for hw:CARD=$DAC_CARD, name \"$ROOM_NAME\""; return 0; }
  local i
  for i in $(seq 1 20); do sudo -u "$AUDIO_USER" pibuz ping >/dev/null 2>&1 && break; sleep 0.5; done
  qobuz_set audio.backend               alsa
  qobuz_set audio.alsa_plugin           hw
  qobuz_set audio.device                "hw:CARD=$DAC_CARD,DEV=0"
  qobuz_set audio.alsa_hardware_volume  false
  qobuz_set audio.normalization_enabled false
  qobuz_set audio.volume_curve          linear   # player-guard carries the shared level over exactly
  qobuz_set qconnect.device_name        "$ROOM_NAME"
  qobuz_set hooks.script                /usr/local/bin/qobuz-hook
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

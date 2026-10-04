# Source: Spotify Connect, via spotifyd (https://github.com/Spotifyd/spotifyd,
# GPL-3.0). The prebuilt binary from this project's releases is spotifyd
# SPOTIFYD_VERSION with patches/spotifyd-linear-volume.patch and
# patches/spotifyd-perceptual-volume.patch (the DAC's mixer in dB, on the perceptual
# curve, instead of spotifyd's hard-coded 60 dB curve); BUILD=1 builds it here.

SPOTIFYD_VERSION=v0.4.2

src_spotify_questions() { :; }

src_spotify_install() {
  say "Spotify Connect (spotifyd)"
  apt_install libasound2t64 libdbus-1-3 dbus
  if [ -x /usr/local/bin/spotifyd ] && [ -z "${BUILD:-}" ]; then
    info "already installed: $(/usr/local/bin/spotifyd --version 2>/dev/null)"
  elif ! fetch_binary spotifyd /usr/local/bin/spotifyd; then
    spotify_build
  fi
  if [ -z "$DRY_RUN" ] && ldd /usr/local/bin/spotifyd | grep -q "not found"; then
    die "spotifyd is missing libraries: $(ldd /usr/local/bin/spotifyd | grep 'not found' | tr -s ' ')"
  fi

  spotify_write_conf

  # Let spotifyd register on the system bus, and root (player-guard) pause it
  write_file /etc/dbus-1/system.d/spotifyd.conf <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="$AUDIO_USER">
    <allow own_prefix="rs.spotifyd"/>
    <allow own_prefix="org.mpris.MediaPlayer2.spotifyd"/>
    <allow send_destination_prefix="rs.spotifyd"/>
    <allow send_destination_prefix="org.mpris.MediaPlayer2.spotifyd"/>
  </policy>
  <policy user="root">
    <allow send_destination_prefix="rs.spotifyd"/>
    <allow send_destination_prefix="org.mpris.MediaPlayer2.spotifyd"/>
  </policy>
</busconfig>
EOF
  run systemctl reload dbus

  write_file /etc/systemd/system/spotifyd.service <<EOF
[Unit]
Description=Spotify Connect ($ROOM_NAME)
After=network-online.target sound.target dbus.service
Wants=network-online.target

[Service]
User=$AUDIO_USER
SupplementaryGroups=audio
CacheDirectory=spotifyd
ExecStart=/usr/local/bin/spotifyd --no-daemon --config-path /etc/spotifyd.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable spotifyd >/dev/null 2>&1
  run systemctl restart spotifyd
}

# /etc/spotifyd.conf: output device and volume follow the room's settings
spotify_write_conf() {
  local format volume
  format=$(spotify_format)
  if [ -n "${MIXER_CONTROL:-}" ]; then
    # spotifyd 0.4: "mixer" is the ALSA device, "control" the control's name
    volume="volume_controller = \"alsa\"
mixer = \"hw:CARD=$DAC_CARD\"
control = \"$MIXER_CONTROL\""
  else
    volume='volume_controller = "softvol"'
  fi
  write_file /etc/spotifyd.conf <<EOF
[global]
device_name = "$ROOM_NAME"
device_type = "speaker"
backend = "alsa"
device = "$(out_device)"
audio_format = "$format"
bitrate = 320
$volume
volume_normalisation = false
cache_path = "/var/cache/spotifyd"
no_audio_cache = true
on_song_change_hook = "/usr/local/bin/spotify-hook"
use_mpris = true
dbus_type = "system"
EOF

}

# Output rate switched: new device, restart (Spotify reconnects by itself)
src_spotify_output() {
  spotify_write_conf
  run systemctl restart spotifyd
}

# The best sample format the DAC takes on its raw hw device. Most USB DACs
# refuse 16-bit there; S/PDIF often tops out at 24.
spotify_format() {
  local formats
  [ -n "$DRY_RUN" ] && { echo S32; return 0; }   # a dry run doesn't open the DAC
  formats=$(aplay -D "hw:CARD=$DAC_CARD,DEV=0" --dump-hw-params -d 1 /dev/zero 2>&1 | sed -n 's/^FORMAT: *//p')
  case " $formats " in
    *" S32_LE "*) echo S32 ;;
    *" S24_LE "*) echo S24 ;;
    *" S24_3LE "*) echo S24_3 ;;
    "  ") echo S32 ;;   # DAC busy (something playing): the most common choice
    *) echo S16 ;;
  esac
}

# From source (20-40 min on a Pi 4), with the linear volume patch
spotify_build() {
  info "building spotifyd $SPOTIFYD_VERSION from source (20-40 min on a Pi 4)"
  apt_install build-essential pkg-config git libasound2-dev libdbus-1-dev libssl-dev
  run sudo -u "$AUDIO_USER" sh -c 'command -v cargo >/dev/null || [ -x "$HOME/.cargo/bin/cargo" ] || curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal'
  local src; src=$(getent passwd "$AUDIO_USER" | cut -d: -f6)/.cache/spotifyd-src
  run rm -rf "$src"
  run sudo -u "$AUDIO_USER" git clone -q --depth 1 --branch "$SPOTIFYD_VERSION" https://github.com/Spotifyd/spotifyd "$src"
  run sudo -u "$AUDIO_USER" git -C "$src" apply "$HOMEAUDIO/patches/spotifyd-linear-volume.patch"
  # Perceptual volume on the DAC's mixer, the same curve as pibuz and player-guard
  run sudo -u "$AUDIO_USER" git -C "$src" apply "$HOMEAUDIO/patches/spotifyd-perceptual-volume.patch"
  run sudo -u "$AUDIO_USER" sh -c "cd '$src' && \$HOME/.cargo/bin/cargo build --release --locked --no-default-features --features alsa_backend,dbus_mpris"
  run systemctl stop spotifyd 2>/dev/null || true
  run install -m 755 "$src/target/release/spotifyd" /usr/local/bin/spotifyd
}

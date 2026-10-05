# Source: AirPlay 2, via shairport-sync + nqptp (https://github.com/mikebrady),
# built from source with metadata and MPRIS support (~10 min on a Pi 4).

src_airplay_questions() { :; }

src_airplay_install() {
  say "AirPlay 2 (shairport-sync)"
  if command -v shairport-sync >/dev/null && shairport-sync -V 2>/dev/null | grep -q AirPlay2 && [ -z "${BUILD:-}" ]; then
    info "already installed: $(shairport-sync -V)"
  else
    airplay_build
  fi

  # airplay-start/-stop (run by shairport-sync) read /etc/player-guard.env
  run usermod -aG audioguard shairport-sync
  airplay_write_conf
  run systemctl enable nqptp shairport-sync >/dev/null 2>&1
  run systemctl restart nqptp shairport-sync
}

# /etc/shairport-sync.conf: output device and volume follow the room's settings
airplay_write_conf() {
  local mixer=""
  [ -n "${MIXER_CONTROL:-}" ] && mixer=" mixer_control_name = \"$MIXER_CONTROL\"; mixer_device = \"hw:CARD=$DAC_CARD\";"
  write_file /etc/shairport-sync.conf <<EOF
general = { name = "$ROOM_NAME"; output_backend = "alsa"; mpris_service_bus = "system"; };
alsa = { output_device = "$(out_device airplay)"; disable_standby_mode = "never";$mixer };
metadata = {
    enabled = "yes";
    include_cover_art = "yes";
    cover_art_cache_directory = "/run/player-guard/airplay-cover";
};
sessioncontrol = {
    run_this_before_play_begins = "/usr/local/bin/airplay-start";
    run_this_after_play_ends = "/usr/local/bin/airplay-stop";
    wait_for_completion = "yes";
    allow_session_interruption = "yes";
};
EOF
}

# Output rate switched: new device, restart
src_airplay_output() {
  airplay_write_conf
  run systemctl restart shairport-sync
}

airplay_build() {
  local src=/usr/local/src
  info "building nqptp + shairport-sync (about 10 min on a Pi 4)"
  apt_install --no-install-recommends \
    build-essential git autoconf automake libtool pkg-config xxd \
    libpopt-dev libconfig-dev libasound2-dev avahi-daemon libavahi-client-dev \
    libssl-dev libsoxr-dev libsodium-dev uuid-dev libgcrypt20-dev \
    libavutil-dev libavcodec-dev libavformat-dev libswresample-dev \
    libplist-dev libplist-utils systemd-dev libglib2.0-dev
  run mkdir -p "$src"
  [ -d "$src/nqptp" ] || run git clone -q --depth 1 https://github.com/mikebrady/nqptp.git "$src/nqptp"
  run sh -c "cd '$src/nqptp' && autoreconf -fi && ./configure --with-systemd-startup && make -j\$(nproc) && make install"
  [ -d "$src/shairport-sync" ] || run git clone -q --depth 1 https://github.com/mikebrady/shairport-sync.git "$src/shairport-sync"
  run sh -c "cd '$src/shairport-sync' && autoreconf -fi && ./configure \
    --sysconfdir=/etc --with-alsa --with-soxr --with-avahi --with-ssl=openssl \
    --with-systemd-startup --with-airplay-2 --with-metadata --with-mpris-interface \
    && make -j\$(nproc) && make install"
  run systemctl daemon-reload
}

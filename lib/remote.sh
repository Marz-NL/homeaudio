# Remote: the web page for every room, on a machine that isn't a room. It runs the
# room's playerui as a service with no helper and no sound card, and finds the rooms on
# the network by itself (avahi). Use it instead of a room on the same machine.

REMOTE_CONF=/etc/homeaudio/remote.toml
REMOTE_UNIT=/etc/systemd/system/homeaudio-remote.service

remote_main() {
  need_root remote
  say "Remote: the web page for every room"
  if systemctl is-enabled -q playerui 2>/dev/null; then
    die "this machine is a room (its playerui runs): a room and a remote can't share port 8189"
  fi
  . "$HOMEAUDIO/lib/room.sh"

  apt_install avahi-daemon avahi-utils curl
  id playerui >/dev/null 2>&1 || run useradd --system --no-create-home --shell /usr/sbin/nologin playerui
  # Built from this repo, the same code as the rooms (not the latest release)
  room_build_webui

  # No rooms listed: the rooms are found on the network by themselves
  run install -D -m 644 "$HOMEAUDIO/webui/config/remote.example.toml" "$REMOTE_CONF"
  write_file "$REMOTE_UNIT" <<'EOF'
[Unit]
Description=homeaudio remote: the web page for every room
After=network-online.target avahi-daemon.service
Wants=network-online.target

[Service]
User=playerui
ExecStart=/usr/local/bin/playerui /etc/homeaudio/remote.toml 0.0.0.0:8189
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable --now avahi-daemon
  run systemctl enable --now homeaudio-remote
  run systemctl restart homeaudio-remote
  info "the rooms show up at http://$(uname -n).local:8189"
}

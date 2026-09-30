# uninstall: take a room off this Pi - everything install.sh room/add/rate put
# here. Keeps apt packages (other software may use them), the HAT line in
# config.txt, and this checkout. Keeps the answers and the apps' logins
# (Qobuz, Music Assistant player) too, unless --purge. Sourced by install.sh.

. "$HOMEAUDIO/lib/room.sh"   # the paths (ENV_FILE, MANIFEST)

UNINSTALL_UNITS="player-guard player-guard-helper playerui now-playing sendspin pibuz spotifyd shairport-sync nqptp"

uninstall_main() {
  need_root uninstall
  local home user=${AUDIO_USER:-}
  [ -n "$user" ] || user=$(sed -n 's/^PIBUZ_USER=//p' "$ENV_FILE" 2>/dev/null)
  home=$( [ -n "$user" ] && getent passwd "$user" | cut -d: -f6 )

  say "Uninstall homeaudio from this Pi${ROOM_NAME:+ ($ROOM_NAME)}"
  info "stops and removes: player-guard, playerui, now-playing, and the sources"
  info "(pibuz, spotifyd, shairport-sync + nqptp, sendspin), CamillaDSP and their settings."
  info "keeps: apt packages, the HAT line in /boot/firmware/config.txt, $HOMEAUDIO"
  if [ -n "${PURGE:-}" ]; then
    info "--purge: also the remembered answers and the apps' logins/caches${home:+ in $home}"
  else
    info "keeps: the answers (/etc/homeaudio/install.conf) and the apps' logins - add --purge for those"
  fi
  if [ -z "${ASSUME_YES:-}" ] && [ -z "${DRY_RUN:-}" ]; then
    [ -t 0 ] || die "not a terminal: add --yes to uninstall"
    local answer; read -r -p "    Go ahead? (y/n) [n]: " answer
    case "$answer" in [Yy]*) ;; *) say "Nothing removed."; exit 0 ;; esac
  fi

  say "Stopping"
  local u
  for u in $UNINSTALL_UNITS; do
    systemctl cat "$u" >/dev/null 2>&1 || continue
    run systemctl disable --now "$u" >/dev/null 2>&1 || true
  done

  say "Removing"
  # our units, and the ones shairport-sync's and nqptp's `make install` put
  uninstall_rm /etc/systemd/system/{player-guard,player-guard-helper,playerui,now-playing,sendspin,pibuz,spotifyd}.service \
               /usr/lib/systemd/system/{shairport-sync,nqptp}.service /lib/systemd/system/{shairport-sync,nqptp}.service
  run systemctl daemon-reload
  # programs
  uninstall_rm /usr/local/bin/{player-guard,qobuz-hook,spotify-hook,airplay-start,airplay-stop,now-playing} \
               /usr/local/bin/{playerui,player-guard-helper,pibuz,spotifyd,shairport-sync,nqptp,camilladsp} \
               /usr/local/bin/ma-{stop,pause,play} /usr/local/share/man/man1/shairport-sync.1 \
               "$ALSA_CDSP_SO" /usr/local/lib/homeaudio
  if [ -n "$home" ] && [ -x "$home/.local/bin/uv" ] && [ -e "$home/.local/bin/sendspin" ]; then
    run sudo -u "$user" "$home/.local/bin/uv" tool uninstall -q sendspin || true
  fi
  # settings
  uninstall_rm "$ENV_FILE" "$MANIFEST" "$OUT_CONF" "$OUT_TARGET" /etc/homeaudio/cdsp-dac \
               /etc/tmpfiles.d/{player-guard,homeaudio-cdsp}.conf /etc/avahi/services/homeaudio.service \
               /etc/spotifyd.conf /etc/shairport-sync.conf /etc/shairport-sync.conf.sample \
               /etc/dbus-1/system.d/{spotifyd,shairport-sync-mpris,shairport-sync-dbus}.conf \
               /run/player-guard /run/homeaudio-cdsp
  # users and groups made for it (the audio user stays; leaving audioguard
  # happens with the group)
  getent passwd playerui >/dev/null && run userdel playerui
  getent passwd shairport-sync >/dev/null && run userdel shairport-sync
  getent group shairport-sync >/dev/null && run groupdel shairport-sync
  getent group audioguard >/dev/null && run groupdel audioguard

  if [ -n "${PURGE:-}" ]; then
    [ -n "$home" ] && uninstall_rm "$home"/.config/{pibuz,qbz,sendspin} "$home"/.cache/{pibuz,qbz}
    uninstall_rm "$CONF" /etc/homeaudio "$LOG"
  fi

  say "Done"
  [ -n "${MA_URL:-}" ] && info "Music Assistant still lists \"${ROOM_NAME:-this room}\": remove the player there if you like."
  info "The apps forget this room by themselves once it's gone from the network."
  info "The installer itself: sudo rm -rf $HOMEAUDIO"
}

# uninstall_rm <path>... - remove what exists, say so
uninstall_rm() {
  local p
  for p in "$@"; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    run rm -rf "$p"
  done
}

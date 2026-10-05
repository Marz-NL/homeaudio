# doctor: check what is installed and running, and say what to do about it.
# Read-only - changes nothing. Sourced by install.sh.

DOC_PROBLEMS=0
ok()   { printf '    ok    %s\n' "$*"; }
bad()  { printf '    FIX   %s\n' "$1"; [ -n "${2:-}" ] && printf '          -> %s\n' "$2"; DOC_PROBLEMS=$((DOC_PROBLEMS + 1)); }
note() { printf '    --    %s\n' "$*"; }

doctor_main() {
  if [ -f /etc/player-guard-services.toml ]; then doctor_room; fi
  if systemctl is-enabled -q homeaudio-remote 2>/dev/null; then
    say "Remote"; doctor_http "overview page" "http://localhost:8189/status"
  fi
  if systemctl cat qobuz-proxy >/dev/null 2>&1 || { command -v docker >/dev/null && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx qobuz-proxy; }; then
    say "HEOS bridge"; doctor_http "qobuz-proxy" "http://localhost:8689/api/status"; doctor_http "heos-guard" "http://localhost:8091/api/status"
  fi
  [ -f /etc/player-guard-services.toml ] || [ "$DOC_PROBLEMS" -gt 0 ] || note "nothing of homeaudio found on this machine - run: sudo ./install.sh room"
  echo
  if [ "$DOC_PROBLEMS" -eq 0 ]; then say "All good."; else say "$DOC_PROBLEMS thing(s) to fix, see FIX above."; fi
}

doctor_room() {
  say "Room: ${ROOM_NAME:-$(sed -n 's/^room = "\(.*\)"/\1/p' /etc/player-guard-services.toml)}"
  local card
  card=$(sed -n 's/^USB_CARD=//p' /etc/player-guard.env 2>/dev/null)
  if [ -z "$card" ]; then
    bad "no DAC set in /etc/player-guard.env" "sudo ./install.sh room --reconfigure"
  elif [ -e "/proc/asound/$card" ]; then
    ok "DAC $card is present"
  else
    bad "DAC $card is missing" "check the cable/HAT, then reboot; cards now: $(dac_list | cut -d'|' -f1 | tr '\n' ' ')"
  fi

  local rate engine
  rate=$(sed -n 's/^rate = "\(.*\)"/\1/p' /etc/player-guard-services.toml)
  engine=$(sed -n 's/^engine = "\(.*\)"/\1/p' /etc/player-guard-services.toml)
  OUTPUT_RATE=${rate:-native}
  OUTPUT_ENGINE=${engine:-camilladsp}
  if ! out_cdsp; then
    if out_fixed; then bad "output is set to $(out_label) without CamillaDSP" "sudo ./install.sh rate ${rate}"
    else ok "output: no conversion, straight on the DAC"; fi
  elif [ ! -f "$OUT_CONF" ] || [ ! -x /usr/local/bin/camilladsp ] || [ ! -f "$ALSA_CDSP_SO" ] || [ ! -x "$OUT_GEN" ]; then
    bad "output goes through CamillaDSP, but part of it is missing" "sudo ./install.sh rate direct && sudo ./install.sh rate ${rate}"
  elif [ "$(cat "$OUT_TARGET" 2>/dev/null)" != "$OUTPUT_RATE" ]; then
    bad "CamillaDSP is set to $(cat "$OUT_TARGET" 2>/dev/null), the web page says $(out_label)" "sudo ./install.sh rate ${rate}"
  else
    ok "output: $(out_label), through CamillaDSP ($(/usr/local/bin/camilladsp --version 2>/dev/null | awk '{print $2}'))"
  fi
  doctor_unit player-guard "one source at a time" required
  doctor_unit player-guard-helper "playerui's privileged helper" required
  doctor_unit playerui "web page" required
  doctor_unit now-playing "now playing" required
  doctor_unit pibuz "Qobuz Connect"
  doctor_unit spotifyd "Spotify Connect"
  doctor_unit shairport-sync "AirPlay 2"
  doctor_unit sendspin "Music Assistant player"
  doctor_http "playerui" "http://localhost:8189/status"

  if systemctl is-active -q pibuz && [ "$(id -u)" -ne 0 ]; then
    note "pibuz: run doctor with sudo to check that it answers"
  elif systemctl is-active -q pibuz; then
    if runuser -u "$(sed -n 's/^PIBUZ_USER=//p' /etc/player-guard.env)" -- pibuz ping >/dev/null 2>&1; then
      ok "pibuz answers"
      local curve
      curve=$(runuser -u "$(sed -n 's/^PIBUZ_USER=//p' /etc/player-guard.env)" -- pibuz settings show 2>/dev/null | awk '$1 == "audio.volume_curve" {print $3}')
      if grep -q '^software_sources_follow = true' /etc/player-guard-services.toml && [ "$curve" != linear ]; then
        bad "pibuz volume curve is '$curve': Qobuz won't match the other sources' volume" "sudo ./install.sh add qobuz"
      fi
    else
      bad "pibuz runs but doesn't answer" "journalctl -u pibuz -n 30"
    fi
  fi

  if grep -q '^MA_URL=.' /etc/player-guard.env 2>/dev/null; then
    . /etc/player-guard.env
    if curl -fsS -m 5 -X POST "$MA_URL/api" -H "Content-Type: application/json" -H "Authorization: Bearer $MA_TOKEN" \
         -d '{"message_id":"doctor","command":"players/all","args":{}}' >/dev/null 2>&1; then
      ok "Music Assistant answers at $MA_URL"
      [ -n "${MA_PLAYER:-}" ] || bad "Music Assistant player id unknown" "sudo ./install.sh add ma"
    else
      bad "Music Assistant doesn't answer at $MA_URL (address or token wrong?)" "sudo ./install.sh add ma --reconfigure"
    fi
  fi

  local warnings
  warnings=$(journalctl -u player-guard --since "-1 day" -o cat --no-pager 2>/dev/null | grep -c WARNING || true)
  if [ "$warnings" -gt 0 ]; then
    note "player-guard logged $warnings warning(s) in the last day:"
    journalctl -u player-guard --since "-1 day" -o cat --no-pager | grep WARNING | tail -3 | sed 's/^/          /'
  fi
}

# doctor_unit <unit> <what> [required]
doctor_unit() {
  if ! systemctl cat "$1" >/dev/null 2>&1; then
    [ -n "${3:-}" ] && bad "$2 ($1) is not installed" "sudo ./install.sh room"
    return 0
  fi
  if systemctl is-active -q "$1"; then
    ok "$2 ($1) running"
  elif ! systemctl is-enabled -q "$1" 2>/dev/null; then
    note "$2 ($1) is switched off (turn it on in playerui)"
  else
    bad "$2 ($1) is not running" "journalctl -u $1 -n 30   (then: sudo systemctl restart $1)"
  fi
}

doctor_http() {
  if curl -fsS -m 3 -o /dev/null "$2" 2>/dev/null; then ok "$1 answers ($2)"; else bad "$1 doesn't answer at $2"; fi
}

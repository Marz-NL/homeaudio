# The splash: the first screen of a room setup, and its readme. Up and down (or j and k)
# move the highlight, Enter opens a page, any key goes back from a page, q quits.
# Only on a terminal: install.sh shows it before anything is logged or changed.

SPLASH_W=72
SPLASH_ITEMS=("How the sound flows" "The programs used" "The fixed way" "Options to come" "Pairing" "Start the setup")

# A box of the given lines (stdin), with a title. Plain ASCII, so the edges line up.
splash_box() {
  local title=$1 line rule
  rule=$(printf '%*s' $((SPLASH_W + 2)) '' | tr ' ' '-')
  printf '+%s+\n' "$rule"
  printf '| %-*s |\n' "$SPLASH_W" "$title"
  printf '+%s+\n' "$rule"
  while IFS= read -r line; do printf '| %-*s |\n' "$SPLASH_W" "$line"; done
  printf '+%s+\n' "$rule"
}

splash_page() {
  case $1 in
    0) splash_box "How the sound flows" <<'EOF'
Every source plays into the same loopback card, one subdevice each:

  Qobuz app ---> pibuz         (Qobuz Connect)        subdevice 0
  Spotify  ---> spotifyd       (Spotify Connect)      subdevice 1
  AirPlay  ---> shairport-sync (AirPlay 2)            subdevice 2
  Music Assistant -> sendspin  (Music Assistant)      subdevice 3

      +--------------------------------------------------------+
      | player-guard: one source plays, the others pause        |
      +--------------------------------------------------------+
                               |  the playing source's subdevice
                               v
      +--------------------------------------------------------+
      | meter-chain + CamillaDSP: capture, output rate, meters  |
      +--------------------------------------------------------+
                               |  native, or the rate you choose
                               v
                       DAC  (the room's sound card)
EOF
      ;;
    1) splash_box "The programs used" <<'EOF'
  pibuz 2.6.0          Qobuz Connect, headless (the Qobuz app)
  spotifyd 0.4.2       Spotify Connect, with a perceptual volume patch
  shairport-sync       AirPlay 2 (with nqptp for timing)
  sendspin             Music Assistant player client, patched
  CamillaDSP 4.1.3     the converter: output rate and the meters
  player-guard         who may play: one source at a time
  meter-chain          follows the playing source, runs CamillaDSP
  playerui             the room's web page (port 8189)
  now-playing          track and cover art (port 8190)
  avahi                announces the room on the network
EOF
      ;;
    2) splash_box "The fixed way" <<'EOF'
This is the fixed way of setting up a room. Every room gets the
same path, so a fault is always looked for in the same place:

  - every source plays into the same loopback card
  - CamillaDSP is always in the path: it carries the meters
  - one source at a time takes the DAC; the others pause
  - the output is native (the music's own rate), or one rate you choose

The path itself is not up for choice. Only the settings on top of
it are.
EOF
      ;;
    3) splash_box "Options to come" <<'EOF'
The next steps add options to this setup: which sources a room has,
how the DAC and its volume are named, and the output rate.

Most of them can later be changed on the room's web page, without
running the installer again: open http://<room>.local:8189

The signal path stays fixed.
EOF
      ;;
    4) splash_box "Pairing" <<'EOF'
When the setup has finished, the room shows up in each app:
  Qobuz app         choose the room in the device list
  Spotify           the room is listed under Connect devices
  AirPlay           the room is listed as a speaker
  Music Assistant   the room is listed as a player
Qobuz is logged in from the Qobuz app, not in this setup.
EOF
      ;;
  esac
}

# The menu, with the highlighted item in reverse video
splash_menu() {
  local sel=$1 i label
  printf '\033[H\033[2J'
  splash_box "homeaudio - room setup" <<EOF
Up and down (or j, k) move. Enter opens. q quits.

EOF
  for i in "${!SPLASH_ITEMS[@]}"; do
    label=${SPLASH_ITEMS[$i]}
    if [ "$i" -eq "$sel" ]; then printf '\033[7m  > %-*s\033[0m\n' "$SPLASH_W" "$label"
    else printf '    %-*s\n' "$SPLASH_W" "$label"; fi
  done
}

# Shows the splash until the setup is started. Returns then; q exits the installer.
splash_show() {
  local sel=0 key seq n=${#SPLASH_ITEMS[@]}
  printf '\033[?25l'
  trap 'printf "\033[?25h\033[0m\n"' EXIT
  while :; do
    splash_menu "$sel"
    IFS= read -rsn1 key
    case $key in
      $'\e') IFS= read -rsn2 -t 0.1 seq; case $seq in '[A') key=k ;; '[B') key=j ;; *) key=esc ;; esac ;;
    esac
    case $key in
      k) sel=$(( (sel + n - 1) % n )) ;;
      j) sel=$(( (sel + 1) % n )) ;;
      q) exit 0 ;;
      esc) ;;
      '')
        if [ "$sel" -eq $((n - 1)) ]; then printf '\033[?25h\033[0m\n'; trap - EXIT; return 0; fi
        printf '\033[H\033[2J'; splash_page "$sel"
        printf '\n  any key goes back\n'
        IFS= read -rsn1 _
        ;;
    esac
  done
}

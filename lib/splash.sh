# The splash: the first screen of the installer. It names the repo, asks whether to read
# the readme first, and shows the readme as a scrollable page. Only on a terminal:
# install.sh shows it before anything is logged or changed.
#
# Keys: y or n answer the question. In the readme: j or down, k or up, space or PgDn,
# b or PgUp scroll; g goes to the top; q leaves the readme and starts the setup.

SPLASH_TITLE="homeaudio  Installer"

splash_header() {
  printf '\033[H\033[2J'
  printf '\033[1m%s\033[0m\n' "$SPLASH_TITLE"
  printf '%s\n\n' "$(printf '%*s' ${#SPLASH_TITLE} '' | tr ' ' '=')"
}

# The readme: plain text, one line per row
splash_readme() {
  cat <<'EOF'
WHAT THIS INSTALLER SETS UP

A room: a Raspberry Pi with a DAC (a sound card), playing music from the
Qobuz app, Spotify, AirPlay and Music Assistant, with a web page for the room.


1. HOW THE SOUND FLOWS

  Qobuz app ---> pibuz          (Qobuz Connect)        subdevice 0
  Spotify  ---> spotifyd        (Spotify Connect)      subdevice 1
  AirPlay  ---> shairport-sync  (AirPlay 2)            subdevice 2
  Music Assistant -> sendspin   (Music Assistant)      subdevice 3
          |
          |   all four write into one loopback card (snd-aloop)
          v
  +-----------------------------------------------------------+
  | player-guard: one source plays, the others pause          |
  +-----------------------------------------------------------+
          |   the playing source's subdevice
          v
  +-----------------------------------------------------------+
  | meter-chain + CamillaDSP: capture, output rate, meters    |
  +-----------------------------------------------------------+
          |   native, or the rate you chose
          v
  DAC (the room's sound card)

  The web page (playerui, port 8189) reads the levels from CamillaDSP and
  shows them as meters.


2. PROGRAMS USED

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


3. FIXED SETTINGS

These are the same in every room, on purpose, so a fault is always looked for
in the same place:

  - every source plays into the same loopback card, one subdevice each
  - CamillaDSP is always in the path: it carries the meters
  - one source at a time takes the DAC; the others pause
  - the path itself is not up for choice


4. VARIABLE SETTINGS

You choose these during the setup:

  - the room name (it is the name the apps show)
  - the DAC, and which control is its volume
  - which sources the room has: Qobuz, Spotify, AirPlay, Music Assistant
  - Music Assistant: its address and the player for this room
  - the output rate: native (the music's own rate), or one rate the DAC supports
  - an optional Home Assistant webhook for the now-playing information

Most of these can be changed later on the room's web page, without running
the installer again: open http://<room>.local:8189


5. PAIRING

When the setup has finished, the room shows up in each app:

  Qobuz app         choose the room in the device list
  Spotify           the room is listed under Connect devices
  AirPlay           the room is listed as a speaker
  Music Assistant   the room is listed as a player

Qobuz is logged in from the Qobuz app, not in this setup.


6. COMMANDS

  sudo ./install.sh room            set up a room (this screen)
  sudo ./install.sh add <source>    add ma, qobuz, spotify or airplay later
  sudo ./install.sh rate <rate>     native, or a rate the DAC supports; switched live
  ./install.sh doctor               check what is installed and running
  sudo ./install.sh uninstall       remove it again (--purge: also answers and logins)

Two other roles exist: hub (an overview page for several rooms) and heos.
EOF
}

# Shows the readme, scrollable. Returns when q is pressed.
splash_readme_show() {
  local -a R
  local top=0 key seq rows h
  mapfile -t R < <(splash_readme)
  while :; do
    rows=$(tput lines 2>/dev/null || echo 24)
    h=$(( rows - 4 )); [ "$h" -lt 5 ] && h=5
    [ $top -gt $(( ${#R[@]} - h )) ] && top=$(( ${#R[@]} - h ))
    [ $top -lt 0 ] && top=0
    splash_header
    printf '%s\n' "${R[@]:top:h}"
    printf '\n\033[7m  j/k scroll   space page   g top   q start the setup  (%d%%)  \033[0m' \
      $(( (top + h) * 100 / ${#R[@]} ))
    IFS= read -rsn1 key
    case $key in
      $'\e') IFS= read -rsn2 -t 0.1 seq; case $seq in '[A') key=k ;; '[B') key=j ;; '[5') key=b ;; '[6') key=' ' ;; *) key= ;; esac ;;
    esac
    case $key in
      j) top=$(( top + 1 )) ;;
      k) top=$(( top - 1 )) ;;
      ' ') top=$(( top + h - 2 )) ;;
      b) top=$(( top - h + 2 )) ;;
      g) top=0 ;;
      q) return 0 ;;
    esac
    [ $top -lt 0 ] && top=0
  done
}

# Shown first: the readme question. Returns when the setup should start.
splash_show() {
  local key
  printf '\033[?25l'
  trap 'printf "\033[?25h\033[0m\n"' EXIT
  splash_header
  printf 'Requirements\n'
  printf '  - a Raspberry Pi running 64-bit Raspberry Pi OS, on the network\n'
  printf '  - a DAC: a USB or HAT sound card\n'
  printf '  - Music Assistant on the network, if the room should play from it\n\n'
  printf 'What this setup changes on this system\n'
  printf '  - installs and starts the room services: pibuz, spotifyd, shairport-sync,\n'
  printf '    sendspin, player-guard, meter-chain, playerui and now-playing\n'
  printf '  - creates the %s group and adds the audio users to it\n' "$GUARD_GROUP"
  printf '  - writes its settings to /etc/homeaudio and its service files to /etc/systemd\n'
  printf '  - loads the loopback sound card (snd-aloop) at boot\n'
  printf '  - runs the room'"'"'s web page on port 8189\n\n'
  printf 'Read the readme first? (y/n) '
  while :; do
    IFS= read -rsn1 key
    case $key in
      y|Y) splash_readme_show; break ;;
      n|N|'') break ;;
    esac
  done
  printf '\033[?25h\033[0m\n'
  trap - EXIT
}

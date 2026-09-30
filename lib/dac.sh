# DAC detection: which sound card plays the music, and whether it has a
# hardware volume control. Sourced, not run.

# Cards as "id|description", one per line, e.g. "E30|USB-Audio - E30"
dac_list() {
  sed -nE 's/^ *[0-9]+ \[([^] ]+) *\]: (.*)$/\1|\2/p' /proc/asound/cards 2>/dev/null
}

# The likeliest music DAC: anything but HDMI and the Pi's own headphone jack
dac_guess() {
  dac_list | grep -viE '\|.*(hdmi|bcm2835 headphones|headphones)' | head -1 | cut -d'|' -f1
}

# Playback volume controls of card $1, one name per line - exact names,
# trailing spaces included (a Topping E30's control is "E30 ").
dac_mixers() {
  amixer -D "hw:CARD=$1" scontents 2>/dev/null | awk '
    /^Simple mixer control / { name = $0; sub(/^Simple mixer control '\''/, "", name); sub(/'\'',[0-9]+$/, "", name); next }
    /Capabilities:/ && / pvolume/ && name != "" { print name; name = "" }'
}

# The likeliest volume control of card $1: the only one, or a common name
dac_mixer_guess() {
  local mixers
  mixers=$(dac_mixers "$1")
  [ -n "$mixers" ] || return 0
  if [ "$(printf '%s\n' "$mixers" | wc -l)" -eq 1 ]; then printf '%s\n' "$mixers"; return 0; fi
  printf '%s\n' "$mixers" | grep -m1 -E '^(Digital|PCM|Master|Speaker|Headphone)$' \
    || printf '%s\n' "$mixers" | head -1
}

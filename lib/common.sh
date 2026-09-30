# Shared helpers for install.sh: output, questions with remembered answers,
# dry-run. Sourced, not run.

CONF=${HOMEAUDIO_CONF:-/etc/homeaudio/install.conf}
DRY_RUN=${DRY_RUN:-}
ASSUME_YES=${ASSUME_YES:-}
RECONFIGURE=${RECONFIGURE:-}

say()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo: sudo $0 $*"; }

# Run a command, or only show it with --dry-run
run() {
  if [ -n "$DRY_RUN" ]; then printf '    would run: %s\n' "$*"; else "$@"; fi
}

# apt-get install without its progress chatter (errors still show)
apt_install() {
  if [ -n "$DRY_RUN" ]; then printf '    would install: %s\n' "$*"; return 0; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Use-Pty=0 "$@" >/dev/null
}

# Write stdin to a file (mode $2), or only show it with --dry-run
write_file() {
  local path=$1 mode=${2:-644}
  if [ -n "$DRY_RUN" ]; then
    printf '    would write %s:\n' "$path"; sed 's/^/      | /'
  else
    mkdir -p "$(dirname "$path")"
    cat > "$path.tmp" && chmod "$mode" "$path.tmp" && mv "$path.tmp" "$path"
  fi
}

# ---- answers, remembered in $CONF so a re-run asks nothing

conf_load() { [ -r "$CONF" ] && . "$CONF"; return 0; }

conf_set() {
  local key=$1 value=$2
  printf -v "$key" '%s' "$value"
  [ -n "$DRY_RUN" ] && return 0
  mkdir -p "$(dirname "$CONF")"
  touch "$CONF" && chmod 600 "$CONF"
  sed -i "/^$key=/d" "$CONF"
  printf '%s=%q\n' "$key" "$value" >> "$CONF"
}

# Forget an answer (e.g. one that turned out wrong), so the next ask asks again
conf_unset() {
  unset "$1"
  [ -n "$DRY_RUN" ] || [ ! -f "$CONF" ] || sed -i "/^$1=/d" "$CONF"
}

# A remembered answer is used without asking - but shown, so a re-run still
# says what it's doing. The question's own "e.g."/"(...)" hints are left out.
remembered() {
  local label=${1%%, e.g.*}; label=${label%% (*}
  printf '    ✓ %s: %s\n' "$label" "$2"
}

# ask VAR "Question" [default] - keeps a remembered answer unless --reconfigure
ask() {
  local var=$1 question=$2 default=${3:-} answer
  if [ -n "${!var+set}" ] && grep -q "^$var=" "$CONF" 2>/dev/null && [ -z "$RECONFIGURE" ]; then
    remembered "$question" "${!var:-(none)}"; return 0
  fi
  if [ -n "${!var:-}" ] && [ -z "$RECONFIGURE" ]; then return 0; fi
  [ -n "${!var:-}" ] && default=${!var}
  if [ -n "$ASSUME_YES" ] || [ ! -t 0 ]; then
    answer=$default
  else
    read -r -p "    $question${default:+ [$default]}: " answer
    answer=${answer:-$default}
  fi
  conf_set "$var" "$answer"
}

# ask_secret VAR "Question" - like ask, but the answer isn't shown
ask_secret() {
  local var=$1 question=$2 answer tries=0
  if [ -n "${!var:-}" ] && [ -z "$RECONFIGURE" ]; then remembered "${question%% (*}" "(remembered)"; return 0; fi
  if [ -n "$ASSUME_YES" ] || [ ! -t 0 ]; then
    [ -n "${!var:-}" ] || die "$question: no answer remembered and nobody to ask"
    return 0
  fi
  while :; do
    read -r -s -p "    $question${!var:+ [keep current: Enter]}: " answer; echo
    if [ -n "$answer" ]; then conf_set "$var" "$answer"; return 0; fi
    [ -n "${!var:-}" ] && return 0
    tries=$((tries + 1))
    [ "$tries" -lt 3 ] || die "$question: nothing entered"
    info "Nothing entered - paste it and press Enter."
  done
}

# ask_yesno VAR "Question" y|n
ask_yesno() {
  local var=$1 question=$2 default=${3:-n}
  ask "$var" "$question (y/n)" "$default"
  case "${!var}" in [Yy]*) conf_set "$var" y ;; *) conf_set "$var" n ;; esac
}

# ask_choice VAR "Question" default option... - pick one by number or value
ask_choice() {
  local var=$1 question=$2 default=$3 i=1 opt answer
  shift 3
  if [ -n "${!var:-}" ] && [ -z "$RECONFIGURE" ]; then remembered "$question" "${!var}"; return 0; fi
  if [ -z "$ASSUME_YES" ] && [ -t 0 ]; then
    for opt in "$@"; do printf '      %d) %s\n' "$i" "$opt"; i=$((i + 1)); done
  fi
  ask "$var" "$question" "$default"
  answer=${!var}
  if [[ $answer =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le $# ]; then
    conf_set "$var" "${!answer}"
  fi
}

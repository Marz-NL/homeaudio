#!/usr/bin/env python3
# homeaudio: makes sendspin's ALSA volume perceptual, the same curve as pibuz,
# spotifyd and player-guard. Music Assistant's percent becomes a dB level on the
# DAC's mixer (25% about -30 dB, 50% about -18 dB, 75% about -9 dB), and the level
# read back is converted to a percent the same way.
#
# Applied to the installed sendspin package (uv tool), so it is re-run after every
# sendspin install or upgrade (lib/sources/ma.sh does). Idempotent.
#   perceptual-volume.py [path/to/sendspin/alsa_volume.py]
import glob
import os
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else (
    glob.glob("/home/*/.local/share/uv/tools/sendspin/lib/python3*/site-packages/sendspin/alsa_volume.py") or [None])[0]
if not PATH:
    sys.exit("sendspin's alsa_volume.py not found")

# cli.py: HOMEAUDIO_MIXER="<card name>:<element>" names the DAC's mixer. sendspin
# only finds a mixer on the device it plays to, and on a room that plays through the
# loopback that device has none, so the volume would fall back to software gain.
CLI = os.path.join(os.path.dirname(PATH), "cli.py")
cli = open(CLI).read()
if "HOMEAUDIO_MIXER" not in cli:
    anchor = "        alsa_info = await alsa_volume_check_available(audio_device)\n"
    if cli.count(anchor) != 1:
        sys.exit("cli.py anchor not found exactly once")
    cli = cli.replace(anchor, '''        # HOMEAUDIO_MIXER="<card name>:<element>": the DAC's mixer, when the audio
        # goes to a loopback (see homeaudio's pi/sendspin/perceptual-volume.py)
        mixer_env = os.environ.get("HOMEAUDIO_MIXER", "")
        if mixer_env:
            card_name, _, element_name = mixer_env.partition(":")
            card_dir = os.path.realpath(f"/proc/asound/{card_name}")
            alsa_info = (int(os.path.basename(card_dir).replace("card", "")), element_name)
        else:
            alsa_info = await alsa_volume_check_available(audio_device)
''')
    open(CLI, "w").write(cli)
    print("patched:", CLI)

src = open(PATH).read()
if "_perceptual_arg" in src:
    print("already perceptual:", PATH)
    sys.exit(0)

def rep(old, new):
    global src
    if src.count(old) != 1:
        sys.exit(f"anchor not found exactly once: {old[:60]!r}")
    src = src.replace(old, new)

rep("import logging\nimport re\n", "import logging\nimport math\nimport re\n")

rep('''_SWITCH_RE = re.compile(r"\\[(on|off)\\]")
''', '''_SWITCH_RE = re.compile(r"\\[(on|off)\\]")
_DB_RE = re.compile(r"\\[(-?\\d+(?:\\.\\d+)?)dB\\]")

# Perceptual volume: the slider is an exponential taper in gain (homeaudio's curve)
def _perceptual_arg(volume):
    """The amixer argument for a 0-100 volume."""
    if volume <= 0:
        return "0%"
    f = volume / 100
    gain = (math.exp(4 * f) - 1) / (math.exp(4) - 1)
    return f"{20 * math.log10(gain):.2f}dB"

def _volume_from_output(output):
    """0-100 from an amixer sget: the dB level if it shows one, else the raw percent."""
    m = _DB_RE.search(output)
    if m:
        gain = 10 ** (float(m.group(1)) / 20)
        f = math.log(1 + gain * (math.e ** 4 - 1)) / 4
        return max(0, min(100, round(100 * f)))
    m = _VOLUME_RE.search(output)
    return int(m.group(1)) if m else None
''')

rep('''            "amixer",
            "-M",
            "-c",
            self._card,
            "sset",
            self._element,
            "playback",
            f"{volume}%",
            mute_arg,''', '''            "amixer",
            "-c",
            self._card,
            "sset",
            self._element,
            "playback",
            "--",
            _perceptual_arg(volume),
            mute_arg,''')

rep('''            "amixer",
            "-M",
            "-c",
            self._card,
            "sget",''', '''            "amixer",
            "-c",
            self._card,
            "sget",''')

rep('''        vol_match = _VOLUME_RE.search(output)
        switch_match = _SWITCH_RE.search(output)

        if vol_match is None:
            raise RuntimeError(f"Could not parse volume from amixer output: {output!r}")

        volume = int(vol_match.group(1))''', '''        switch_match = _SWITCH_RE.search(output)
        volume = _volume_from_output(output)
        if volume is None:
            raise RuntimeError(f"Could not parse volume from amixer output: {output!r}")''')

open(PATH, "w").write(src)
print("patched:", PATH)

#!/usr/bin/env python3
# homeaudio: Music Assistant 2.10 sends media commands that sendspin's aiosendspin
# 6.x doesn't know (seek, seek_relative, ...). Its state messages then fail to parse,
# so the player never acts on stop/pause from Music Assistant. Commands it doesn't
# know become enum members, which sendspin ignores. Idempotent.
#   media-commands.py [path/to/aiosendspin/models/types.py]
import glob
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else (
    glob.glob("/home/*/.local/share/uv/tools/sendspin/lib/python3*/site-packages/aiosendspin/models/types.py") or [None])[0]
if not PATH:
    sys.exit("aiosendspin's models/types.py not found")
src = open(PATH).read()
if "_missing_" in src:
    print("already accepts unknown commands:", PATH)
    sys.exit(0)
anchor = '    SWITCH = "switch"\n'
if src.count(anchor) != 1:
    sys.exit("MediaCommand anchor not found exactly once")
addition = (
    '\n    @classmethod\n'
    '    def _missing_(cls, value):\n'
    '        member = object.__new__(cls)\n'
    '        member._name_ = str(value).upper()\n'
    '        member._value_ = value\n'
    '        return member\n'
)
src = src.replace(anchor, anchor + addition)
open(PATH, "w").write(src)
print("patched:", PATH)

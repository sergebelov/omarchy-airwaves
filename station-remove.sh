#!/usr/bin/env sh
# Remove a stream from the stations .m3u and trigger an OwnTone library rescan.
#
# usage: station-remove.sh <stream-url> [m3u-path] [owntone-api-base]
#
# Kept as a script rather than inline QML: the edit must drop the URL line
# together with its preceding #EXTINF line, which is unpleasant to escape
# through a Process command array.
set -eu

URL="${1:-}"
M3U="${2:-}"
API="${3:-http://localhost:3689/api}"

[ -n "$URL" ] || exit 0
[ -n "$M3U" ] || M3U="$HOME/Music/radio.m3u"
[ -f "$M3U" ] || exit 0

python3 - "$URL" "$M3U" <<'PY'
import sys, pathlib
url = sys.argv[1].strip()
p = pathlib.Path(sys.argv[2])
lines = p.read_text().splitlines()
out, i = [], 0
while i < len(lines):
    if lines[i].startswith('#EXTINF') and i + 1 < len(lines) and lines[i + 1].strip() == url:
        i += 2
        continue
    if lines[i].strip() == url:
        i += 1
        continue
    out.append(lines[i])
    i += 1
p.write_text('\n'.join(out) + '\n')
PY

curl -fsS --max-time 10 -X PUT "$API/update" >/dev/null 2>&1 || true

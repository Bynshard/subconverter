#!/bin/sh
# Offline regression test for source-section preservation.
#
# Replays a saved Clash subscription dump through a locally built binary and asserts that
# the subscription's own top-level sections (hosts, dns, ...) survive conversion when a
# template is supplied - the exact request OpenClash makes. Needs no panel access.
#
# Usage:
#   sh scripts/offline-regression.sh [dump.yaml]
#
# Environment:
#   DUMP      Clash config to replay (default: newest tmp/raw/*clash*.txt)
#   TEMPLATE  template / rule.ini url
#   BIN       binary under test (default: build/subconverter)
#   PORT      listen port (default: 25509)
#   PREF      preference file to install into the fixture (default: base/pref.example.toml)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/build/subconverter}"
PORT="${PORT:-25509}"
TEMPLATE="${TEMPLATE:-https://raw.githubusercontent.com/Bynshard/clash-rule/refs/heads/master/rule.ini}"
PREF="${PREF:-$ROOT/base/pref.example.toml}"
FIX="$ROOT/tmp/fixture"
OUT="$ROOT/tmp/offline"

DUMP="${1:-${DUMP:-}}"
if [ -z "$DUMP" ]; then
    DUMP="$(ls -t "$ROOT"/tmp/raw/*clash*.txt 2>/dev/null | head -1 || true)"
fi
[ -n "$DUMP" ] && [ -s "$DUMP" ] || {
    echo "no dump given and none found in tmp/raw; run scripts/save-subscription.sh first"
    echo "usage: sh scripts/offline-regression.sh <clash-config.yaml>"
    exit 1
}
[ -x "$BIN" ] || { echo "no binary at $BIN; run: cmake --build build -j\$(nproc)"; exit 1; }

EXPECT_ENTRIES=$(awk '/^hosts:/{f=1;next} f&&/^[a-zA-Z]/{exit} f&&/:/{n++} END{print n+0}' "$DUMP")
EXPECT_PROXIES=$(awk '/^proxies:/{f=1;next} f&&/^[a-zA-Z]/{exit} f&&/name:/{n++} END{print n+0}' "$DUMP")

echo "=== input ==="
echo "dump         : $DUMP ($(wc -c < "$DUMP") bytes)"
echo "sha256       : $(sha256sum "$DUMP" | cut -d' ' -f1)"
echo "hosts entries: $EXPECT_ENTRIES"
echo "proxies      : $EXPECT_PROXIES"
echo "template     : $TEMPLATE"

# fixture mirrors the container layout: CWD holds pref.toml + base/ + snippets/
rm -rf "$FIX" "$OUT"
mkdir -p "$FIX" "$OUT"
cp -r "$ROOT/base/base" "$FIX/base"
cp -r "$ROOT/base/snippets" "$FIX/snippets"
cp -r "$ROOT/base/config" "$FIX/config"
mkdir -p "$FIX/rules" "$FIX/replay"
cp "$PREF" "$FIX/pref.toml"
cp "$DUMP" "$FIX/replay/source.yaml"

pkill -f "subconverter -f .*fixture" 2>/dev/null || true
sleep 1
cd "$FIX"
PORT="$PORT" "$BIN" -f "$FIX/pref.toml" > "$OUT/server.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT INT TERM

i=0
while [ "$i" -lt 40 ]; do
    curl -sS -m 2 "http://127.0.0.1:$PORT/version" >/dev/null 2>&1 && break
    i=$((i + 1)); sleep 0.5
done
VERSION="$(curl -sS -m 5 "http://127.0.0.1:$PORT/version" 2>/dev/null || true)"
[ -n "$VERSION" ] || { echo "server did not start:"; tail -20 "$OUT/server.log"; exit 1; }
echo "service      : $VERSION"
echo

conv() {
    name="$1"; shift
    curl -sS -m 180 -A 'clash.meta' -G \
        --data-urlencode "target=clash" --data-urlencode "url=$FIX/replay/source.yaml" \
        --data-urlencode "new_name=true" --data-urlencode "list=false" --data-urlencode "fdn=true" "$@" \
        -o "$OUT/$name.yaml" "http://127.0.0.1:$PORT/sub"
    printf '%-26s bytes=%-9s hosts=%-2s entries=%-3s dns=%-2s mixed-port=%-2s\n' \
        "$name" "$(wc -c < "$OUT/$name.yaml")" \
        "$(grep -c '^hosts:' "$OUT/$name.yaml" || true)" \
        "$(awk '/^hosts:/{f=1;next} f&&/^[a-zA-Z]/{exit} f&&/:/{n++} END{print n+0}' "$OUT/$name.yaml")" \
        "$(grep -c '^dns:' "$OUT/$name.yaml" || true)" \
        "$(grep -c '^mixed-port:' "$OUT/$name.yaml" || true)"
}

echo "=== cases ==="
conv with_template      --data-urlencode "config=$TEMPLATE"
conv preserve_off       --data-urlencode "config=$TEMPLATE" --data-urlencode "preserve_source=false"
conv preserve_all       --data-urlencode "config=$TEMPLATE" --data-urlencode "preserve_all=true"
conv no_template

entries() { awk '/^hosts:/{f=1;next} f&&/^[a-zA-Z]/{exit} f&&/:/{n++} END{print n+0}' "$OUT/$1.yaml"; }

echo
echo "=== assertions ==="
FAIL=0
[ "$(entries with_template)" -eq "$EXPECT_ENTRIES" ] && echo "ok  : with_template keeps all $EXPECT_ENTRIES hosts entries" \
    || { echo "FAIL: with_template hosts=$(entries with_template) expected=$EXPECT_ENTRIES"; FAIL=1; }
[ "$(grep -c '^dns:' "$OUT/with_template.yaml" || true)" -eq 1 ] && echo "ok  : with_template keeps dns" \
    || { echo "FAIL: dns missing"; FAIL=1; }
[ "$(grep -c '^mixed-port:' "$OUT/with_template.yaml" || true)" -eq 0 ] && echo "ok  : no mixed-port leak" \
    || { echo "FAIL: mixed-port leaked next to port/socks-port"; FAIL=1; }
[ "$(entries preserve_off)" -eq 0 ] && echo "ok  : preserve_source=false drops hosts (switch works)" \
    || { echo "FAIL: preserve_source=false still kept hosts"; FAIL=1; }
[ "$(grep -c '^mixed-port:' "$OUT/preserve_all.yaml" || true)" -eq 0 ] && echo "ok  : preserve_all does not leak deployment-owned keys" \
    || { echo "FAIL: preserve_all leaked mixed-port"; FAIL=1; }
[ "$(entries no_template)" -eq "$EXPECT_ENTRIES" ] && echo "ok  : legacy no-template path keeps hosts" \
    || { echo "FAIL: no_template hosts=$(entries no_template)"; FAIL=1; }

echo
[ "$FAIL" -eq 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }

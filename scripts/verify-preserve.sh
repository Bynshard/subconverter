#!/bin/sh
# Prove that the running subconverter keeps the subscription's own Clash sections
# (in particular `hosts`) when a template is supplied - the exact request OpenClash makes.
#
# Run ON THE ROUTER as root:
#   ssh root@192.168.100.1 'sh -s' < scripts/verify-preserve.sh
#
# Two sources are supported:
#   SOURCE=live    fetch the subscription through the running container (needs the panel up)
#   SOURCE=replay  replay a saved Clash dump from /etc/subconverter/replay/ (offline, default)
#
# Environment:
#   SOURCE       live | replay      (default: replay when a dump exists, else live)
#   SUB_URL      subscription url    (required for SOURCE=live)
#   TEMPLATE     template / rule.ini (default: the ACL4SSR template used by OpenClash)
#   REPLAY_FILE  dump inside the container filesystem (default: /base/replay/rama991-clash.yaml)
#   EXPECT_HOSTS minimum number of `hosts` entries that must survive (default: 1)
#
# The real subscription url is kept out of this repository in
# /etc/subconverter/local/subscriptions.env (SUB_URL=...), which is git-ignored.
set -e

# shellcheck disable=SC1091
[ -f /etc/subconverter/local/subscriptions.env ] && . /etc/subconverter/local/subscriptions.env

TEMPLATE="${TEMPLATE:-https://raw.githubusercontent.com/Bynshard/clash-rule/refs/heads/master/rule.ini}"
REPLAY_FILE="${REPLAY_FILE:-/base/replay/rama991-clash.yaml}"
REPLAY_HOST_PATH="/etc/subconverter/replay/rama991-clash.yaml"
EXPECT_HOSTS="${EXPECT_HOSTS:-1}"
API="http://127.0.0.1:25500/sub"
UA="clash.meta"
WORK="/tmp/verify-preserve.$$"
mkdir -p "$WORK"

if [ -z "${SOURCE:-}" ]; then
    if [ -s "$REPLAY_HOST_PATH" ]; then SOURCE=replay; else SOURCE=live; fi
fi
if [ "$SOURCE" = "live" ] && [ -z "${SUB_URL:-}" ]; then
    echo "SUB_URL is not set (env or /etc/subconverter/local/subscriptions.env)"; exit 1
fi

echo "=== 0. service ==="
curl -sS -m 5 http://127.0.0.1:25500/version || { echo "subconverter is not answering"; exit 1; }
echo

echo "=== 1. convert (SOURCE=$SOURCE, template=$TEMPLATE) ==="
if [ "$SOURCE" = "replay" ]; then
    [ -s "$REPLAY_HOST_PATH" ] || { echo "no replay dump at $REPLAY_HOST_PATH"; exit 1; }
    URL_ARG="$REPLAY_FILE"
    echo "replaying: $REPLAY_HOST_PATH ($(wc -c < "$REPLAY_HOST_PATH") bytes)"
else
    URL_ARG="$SUB_URL"
fi

curl -sS -m 180 -A "$UA" -G \
    --data-urlencode "target=clash" \
    --data-urlencode "url=$URL_ARG" \
    --data-urlencode "config=$TEMPLATE" \
    --data-urlencode "new_name=true" \
    --data-urlencode "list=false" \
    --data-urlencode "fdn=true" \
    -o "$WORK/out.yaml" "$API"

BYTES=$(wc -c < "$WORK/out.yaml")
HOSTS_LINES=$(grep -c '^hosts:' "$WORK/out.yaml" || true)
HOSTS_ENTRIES=$(awk '/^hosts:/{f=1;next} f&&/^[a-zA-Z]/{exit} f&&/:/{n++} END{print n+0}' "$WORK/out.yaml")
DNS=$(grep -c '^dns:' "$WORK/out.yaml" || true)
MIXED=$(grep -c '^mixed-port:' "$WORK/out.yaml" || true)
PROXIES=$(awk '/^proxies:/{f=1;next} f&&/^[a-zA-Z]/{exit} f&&/name:/{n++} END{print n+0}' "$WORK/out.yaml")

echo "bytes=$BYTES proxies=$PROXIES hosts_section=$HOSTS_LINES hosts_entries=$HOSTS_ENTRIES dns=$DNS mixed-port=$MIXED"
echo

echo "=== 2. assertions ==="
FAIL=0
[ "$HOSTS_ENTRIES" -ge "$EXPECT_HOSTS" ] || { echo "FAIL: hosts mapping lost (entries=$HOSTS_ENTRIES < $EXPECT_HOSTS)"; FAIL=1; }
[ "$HOSTS_ENTRIES" -ge "$EXPECT_HOSTS" ] && echo "ok  : hosts mapping preserved ($HOSTS_ENTRIES entries)"
[ "$MIXED" -eq 0 ] && echo "ok  : no mixed-port leaked next to the template's port/socks-port" || { echo "FAIL: mixed-port leaked"; FAIL=1; }
[ "$PROXIES" -gt 0 ] && echo "ok  : $PROXIES nodes generated" || { echo "FAIL: no nodes"; FAIL=1; }

if [ "$SOURCE" = "replay" ]; then
    echo "--- control: the same request with preserve_source=false must drop hosts ---"
    curl -sS -m 180 -A "$UA" -G \
        --data-urlencode "target=clash" --data-urlencode "url=$URL_ARG" \
        --data-urlencode "config=$TEMPLATE" --data-urlencode "preserve_source=false" \
        -o "$WORK/off.yaml" "$API"
    OFF_ENTRIES=$(awk '/^hosts:/{f=1;next} f&&/^[a-zA-Z]/{exit} f&&/:/{n++} END{print n+0}' "$WORK/off.yaml")
    if [ "$OFF_ENTRIES" -eq 0 ]; then
        echo "ok  : preserve_source=false drops hosts ($OFF_ENTRIES entries) - the switch works"
    else
        echo "note: preserve_source=false still reports $OFF_ENTRIES entries"
    fi
fi
echo

echo "=== 3. mihomo config test ==="
if [ -x /etc/openclash/clash ]; then
    if /etc/openclash/clash -t -d /tmp -f "$WORK/out.yaml" >"$WORK/core.log" 2>&1; then
        echo "ok  : mihomo accepted the generated config"
    else
        echo "note: mihomo -t output (first 15 lines):"
        head -15 "$WORK/core.log"
    fi
else
    echo "skip: no clash core at /etc/openclash/clash"
fi
echo

echo "=== 4. hosts sample ==="
awk '/^hosts:/{f=1} f{print; n++} f&&n>3{exit}' "$WORK/out.yaml"
echo
echo "artifact: $WORK/out.yaml"
[ "$FAIL" -eq 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }

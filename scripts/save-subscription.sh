#!/bin/sh
# Archive a subscription's raw answers before anything else touches them.
#
# Panels answer differently per User-Agent and often only for a limited time / a limited
# number of requests, so keep the raw bytes first and convert afterwards. This is the
# "pull first" step of the workflow.
#
# Run on any host that can reach the panel:
#   SUB_URL='https://.../api/v1/...?token=...' sh scripts/save-subscription.sh
#   sh scripts/save-subscription.sh                       # reads local/subscriptions.env
#
# Environment:
#   SUB_URL   subscription url (or put SUB_URL=... in local/subscriptions.env)
#   OUTDIR    destination (default: tmp/raw)
#   UAS       user agents to try (default: the ones this panel distinguishes)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/local/subscriptions.env" ] && . "$ROOT/local/subscriptions.env"
[ -f "$ROOT/tmp/local/subscriptions.env" ] && . "$ROOT/tmp/local/subscriptions.env"

SUB_URL="${SUB_URL:-}"
[ -n "$SUB_URL" ] || { echo "SUB_URL is not set (env or local/subscriptions.env)"; exit 1; }
OUTDIR="${OUTDIR:-$ROOT/tmp/raw}"
UAS="${UAS:-clash.meta|Clash|Shadowrocket/2.2.9|Mozilla/5.0}"
STAMP="$(date +%Y%m%d%H%M%S)"

mkdir -p "$OUTDIR"
echo "== saving raw answers for ${SUB_URL%%\?*} into $OUTDIR =="

OLDIFS="$IFS"; IFS='|'
for ua in $UAS; do
    IFS="$OLDIFS"
    name="$(printf '%s' "$ua" | tr -c 'A-Za-z0-9' '_')"
    out="$OUTDIR/${STAMP}.${name}.txt"
    code="$(curl -sS -L -m 180 -A "$ua" -D "$out.hdr" -o "$out" \
        -w '%{http_code} %{size_download}' "$SUB_URL" 2>&1 || true)"
    printf '%-22s -> %s  %s\n' "$ua" "$code" "$(head -c 16 "$out" 2>/dev/null | tr -d '\n' | tr -c '[:print:]' '.')"
    IFS='|'
done
IFS="$OLDIFS"

echo
echo "== checksums =="
(cd "$OUTDIR" && sha256sum "${STAMP}".*.txt 2>/dev/null)

echo
echo "== which answers are a Clash config (i.e. carry hosts/dns)? =="
for f in "$OUTDIR/${STAMP}".*.txt; do
    [ -s "$f" ] || continue
    if grep -qE '^(proxies|Proxy):' "$f" 2>/dev/null; then
        printf '%-46s CLASH  hosts=%s proxies=%s\n' "$(basename "$f")" \
            "$(awk '/^hosts:/{f=1;next} f&&/^[a-zA-Z]/{exit} f&&/:/{n++} END{print n+0}' "$f")" \
            "$(awk '/^proxies:/{f=1;next} f&&/^[a-zA-Z]/{exit} f&&/name:/{n++} END{print n+0}' "$f")"
    else
        printf '%-46s not-a-clash-config\n' "$(basename "$f")"
    fi
done

echo
echo "Keep the Clash variant for offline replay, e.g.:"
echo "  scp $OUTDIR/${STAMP}.clash_meta.txt root@192.168.100.1:/etc/subconverter/replay/rama991-clash.yaml"

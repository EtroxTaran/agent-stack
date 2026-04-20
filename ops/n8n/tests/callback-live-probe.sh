#!/usr/bin/env bash
# callback-live-probe.sh
#
# Smoke-test der deployed ai-review-callback Webhook-Route.
# Prüft: Endpoint erreichbar, 401 bei invalid signature, 401 bei altem timestamp.
# Kann NICHT type:3 Button-Click testen (erfordert Discord's echten Private-Key
# zur Signatur) — das wird durch callback-logic.test.js unit-tested.
#
# Usage:
#   ./callback-live-probe.sh                    # localhost:5678
#   BASE_URL=https://r2d2.tail4fc6dd.ts.net \
#     ./callback-live-probe.sh                  # public via Funnel

set -euo pipefail

readonly BASE_URL="${BASE_URL:-http://127.0.0.1:5678}"
readonly ENDPOINT="${BASE_URL}/webhook/discord-interaction"

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

echo ">>> Probing ${ENDPOINT}"

# 1. Unsigned request → 401 invalid_signature
response="$(curl -sS -o /tmp/probe.out -w '%{http_code}' -X POST "$ENDPOINT" \
  -H 'Content-Type: application/json' \
  --data-raw '{"type":1}')"
body="$(cat /tmp/probe.out)"

if [[ "$response" == "401" ]] && echo "$body" | grep -qE 'invalid_(signature|timestamp)'; then
    pass "unsigned request rejected with 401 ($body)"
else
    die "unsigned request expected 401 + invalid_signature/timestamp, got ${response}: ${body}"
fi

# 2. Bogus signature + valid-ish timestamp → 401 invalid_signature
now_ts="$(date +%s)"
response="$(curl -sS -o /tmp/probe.out -w '%{http_code}' -X POST "$ENDPOINT" \
  -H 'Content-Type: application/json' \
  -H "X-Signature-Ed25519: $(printf '00%.0s' {1..64})" \
  -H "X-Signature-Timestamp: ${now_ts}" \
  --data-raw '{"type":1}')"
body="$(cat /tmp/probe.out)"

if [[ "$response" == "401" ]] && echo "$body" | grep -q 'invalid_signature'; then
    pass "bogus-sig + fresh-ts rejected with 401 invalid_signature"
else
    die "bogus sig expected 401 invalid_signature, got ${response}: ${body}"
fi

# 3. Replay: bogus signature + old timestamp (10min ago) → 401 invalid_timestamp
old_ts=$((now_ts - 600))
response="$(curl -sS -o /tmp/probe.out -w '%{http_code}' -X POST "$ENDPOINT" \
  -H 'Content-Type: application/json' \
  -H "X-Signature-Ed25519: $(printf '00%.0s' {1..64})" \
  -H "X-Signature-Timestamp: ${old_ts}" \
  --data-raw '{"type":1}')"
body="$(cat /tmp/probe.out)"

if [[ "$response" == "401" ]] && echo "$body" | grep -q 'invalid_timestamp'; then
    pass "old timestamp rejected with 401 invalid_timestamp (replay protection)"
else
    die "old-ts expected 401 invalid_timestamp, got ${response}: ${body}"
fi

echo ""
echo "All live-probe checks passed for ${ENDPOINT}"

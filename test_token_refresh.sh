#!/bin/bash

# Integration test for silent user-to-server token refresh.
#
# GitHub App user tokens expire after ~8h. When the cached access token is
# expired, the wrapper must renew it silently via the broker's
# /user-token/refresh endpoint (using the stored refresh token) instead of
# forcing a fresh interactive device-flow login. It must also:
#   - rotate the stored refresh token (GitHub returns a new one each refresh)
#   - drop the refresh token only when GitHub says it is permanently bad
#   - keep the refresh token on transient failures (e.g. broker missing the
#     endpoint) so a later attempt can still succeed
#
# Uses a fake gh (AI_ALIGNED_GH_BIN), a fake curl (PATH), and an isolated HOME
# so there are no real network calls or shared cache.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$SCRIPT_DIR/executable_gh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

EXPIRED_TOKEN="ghu_EXPIRED_TOKEN_SENTINEL"
REFRESHED_TOKEN="ghu_REFRESHED_TOKEN_SENTINEL"
OLD_REFRESH="REFRESH_TOKEN_V1"
NEW_REFRESH="REFRESH_TOKEN_V2"

# Fake gh: only the freshly refreshed token is accepted by `api user` (the
# validity probe in get_cached_token); the expired token is rejected. Any other
# api/issue call echoes the token it ran with so the test can prove which token
# was used for the actual operation.
cat > "$FAKE_BIN/gh" <<EOF
#!/bin/bash
if [ "\$1" = "api" ] && [ "\$2" = "user" ]; then
    [ "\$GH_TOKEN" = "$REFRESHED_TOKEN" ] && exit 0
    exit 1
fi
echo "USED_TOKEN=\$GH_TOKEN"
exit 0
EOF
chmod +x "$FAKE_BIN/gh"

# Fake curl: responds to /user-token/refresh with whatever REFRESH_RESPONSE
# holds for the current case. Device-flow start/poll return empty so the
# fallback path terminates quickly (no real network, no hanging).
cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/bash
url=""
for a in "$@"; do
    case "$a" in
        http://*|https://*) url="$a" ;;
    esac
done
case "$url" in
    */user-token/refresh) printf '%s' "$REFRESH_RESPONSE" ;;
    *) printf '' ;;
esac
exit 0
EOF
chmod +x "$FAKE_BIN/curl"

CACHE_DIR_REL=".cache/ai-aligned-gh"

# Run the wrapper for an unsafe op (issue create) under AI detection with a
# fresh isolated HOME seeded by the caller. Echoes combined stdout.
run_wrapper() {
    CLAUDE_CODE=1 \
    AI_ALIGNED_GH_BIN="$FAKE_BIN/gh" \
    AS_A_BOT_URL="http://mock.local" \
    HOME="$ISOLATED_HOME" \
    PATH="$FAKE_BIN:$PATH" \
    REFRESH_RESPONSE="$REFRESH_RESPONSE" \
        "$WRAPPER" issue create --repo testowner/testrepo --title t --body b 2>/dev/null
}

setup_home() {
    ISOLATED_HOME="$TMP_DIR/home_$1"
    mkdir -p "$ISOLATED_HOME/$CACHE_DIR_REL"
    printf '%s' "$EXPIRED_TOKEN"  > "$ISOLATED_HOME/$CACHE_DIR_REL/token"
    printf '%s' "$OLD_REFRESH"    > "$ISOLATED_HOME/$CACHE_DIR_REL/refresh_token"
}

# ---------------------------------------------------------------------------
# Case 1: expired token + valid refresh token -> silent refresh
# ---------------------------------------------------------------------------
setup_home "refresh_ok"
REFRESH_RESPONSE="{\"access_token\":\"$REFRESHED_TOKEN\",\"refresh_token\":\"$NEW_REFRESH\",\"expires_in\":28800}"
out="$(run_wrapper)"

if echo "$out" | grep -q "USED_TOKEN=$REFRESHED_TOKEN"; then
    pass "operation used the silently refreshed token"
else
    fail "operation did not use refreshed token (got: $out)"
fi

if [ "$(cat "$ISOLATED_HOME/$CACHE_DIR_REL/token")" = "$REFRESHED_TOKEN" ]; then
    pass "cached access token updated to refreshed token"
else
    fail "cached access token not updated"
fi

if [ "$(cat "$ISOLATED_HOME/$CACHE_DIR_REL/refresh_token")" = "$NEW_REFRESH" ]; then
    pass "refresh token rotated to new value"
else
    fail "refresh token not rotated"
fi

# ---------------------------------------------------------------------------
# Case 2: broker reports bad_refresh_token -> drop refresh token, fall back
# ---------------------------------------------------------------------------
setup_home "bad_refresh"
REFRESH_RESPONSE='{"error":"bad_refresh_token","error_description":"expired"}'
out="$(run_wrapper)"

if [ ! -f "$ISOLATED_HOME/$CACHE_DIR_REL/refresh_token" ]; then
    pass "dead refresh token removed on bad_refresh_token"
else
    fail "refresh token should have been removed on bad_refresh_token"
fi

if ! echo "$out" | grep -q "USED_TOKEN="; then
    pass "did not run the operation after failed refresh (fell back to auth)"
else
    fail "operation ran despite failed refresh (got: $out)"
fi

# ---------------------------------------------------------------------------
# Case 3: broker lacks the endpoint (empty/transient) -> keep refresh token
# ---------------------------------------------------------------------------
setup_home "transient"
REFRESH_RESPONSE=''   # e.g. older broker without /user-token/refresh
run_wrapper >/dev/null

if [ -f "$ISOLATED_HOME/$CACHE_DIR_REL/refresh_token" ] && \
   [ "$(cat "$ISOLATED_HOME/$CACHE_DIR_REL/refresh_token")" = "$OLD_REFRESH" ]; then
    pass "refresh token preserved on transient/missing-endpoint failure"
else
    fail "refresh token should be preserved on transient failure"
fi

echo
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ]

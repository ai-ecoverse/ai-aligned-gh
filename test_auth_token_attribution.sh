#!/bin/bash

# Integration test for the `gh auth token` attribution guard.
#
# Under AI detection the wrapper must return the as-a-bot user-to-server token,
# never the user's personal token — otherwise an agent can capture the personal
# token and call the GitHub API directly, bypassing attribution. A non-AI caller
# must still get their personal token unchanged.
#
# Uses a fake gh (via AI_ALIGNED_GH_BIN) and an isolated HOME so there are no
# real network calls or shared cache.

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

# Sentinels let us prove which token came back.
BOT_TOKEN="ghu_BOT_TOKEN_SENTINEL"
PERSONAL_TOKEN="ghp_PERSONAL_TOKEN_SENTINEL"

# Fake gh: validates any token (api user -> ok) and, for `auth token`, prints
# the PERSONAL token — exactly what the real gh would leak. If the guard works,
# this string must never reach stdout under AI detection.
cat > "$FAKE_BIN/gh" <<EOF
#!/bin/bash
if [ "\$1" = "auth" ] && [ "\$2" = "token" ]; then
    echo "$PERSONAL_TOKEN"
    exit 0
fi
if [ "\$1" = "api" ]; then
    echo '{}'
    exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN/gh"

ISOLATED_HOME="$TMP_DIR/home"
mkdir -p "$ISOLATED_HOME/.cache/ai-aligned-gh"

seed_bot_token() {
    printf '%s' "$BOT_TOKEN" > "$ISOLATED_HOME/.cache/ai-aligned-gh/token"
    chmod 600 "$ISOLATED_HOME/.cache/ai-aligned-gh/token"
}
clear_bot_token() {
    rm -f "$ISOLATED_HOME/.cache/ai-aligned-gh/token"
}

# AI detected (DROID_CLI=1). Point AS_A_BOT_URL at a dead port so any device
# flow attempt fails fast instead of hitting the network.
run_ai() {
    env -i \
        HOME="$ISOLATED_HOME" \
        PATH="$FAKE_BIN:/opt/homebrew/bin:/usr/bin:/bin" \
        AI_ALIGNED_GH_BIN="$FAKE_BIN/gh" \
        AS_A_BOT_URL="http://127.0.0.1:9" \
        DROID_CLI=1 \
        bash "$WRAPPER" "$@"
}

# No AI detected (AMI_PASSTHROUGH forces am-i-ai to report "none").
run_human() {
    env -i \
        HOME="$ISOLATED_HOME" \
        PATH="$FAKE_BIN:/opt/homebrew/bin:/usr/bin:/bin" \
        AI_ALIGNED_GH_BIN="$FAKE_BIN/gh" \
        AMI_PASSTHROUGH=true \
        bash "$WRAPPER" "$@"
}

echo "=== Integration: gh auth token attribution guard ==="

echo ""
echo "--- AI + cached bot token: returns the bot token ---"
seed_bot_token
out=$(run_ai auth token 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$BOT_TOKEN" ]; then
    pass "AI gets the as-a-bot token"
else
    fail "expected '$BOT_TOKEN' rc=0, got '$out' rc=$rc"
fi
if echo "$out" | grep -q "$PERSONAL_TOKEN"; then
    fail "personal token leaked to an AI tool"
else
    pass "personal token never reaches the AI tool"
fi

echo ""
echo "--- No AI detected: personal token passes through unchanged ---"
out=$(run_human auth token 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "$PERSONAL_TOKEN" ]; then
    pass "human still gets their personal token"
else
    fail "expected '$PERSONAL_TOKEN' rc=0, got '$out' rc=$rc"
fi

echo ""
echo "--- AI + no bot token: fails closed, no personal token ---"
clear_bot_token
out=$(run_ai auth token 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "fails closed when no bot token is available (rc=$rc)"
else
    fail "expected non-zero exit when no bot token, got rc=$rc out='$out'"
fi
if echo "$out" | grep -q "$PERSONAL_TOKEN"; then
    fail "personal token leaked on the no-bot-token path"
else
    pass "no personal token on stdout when failing closed"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1
exit 0

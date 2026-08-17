#!/bin/bash

# Integration tests for device-flow state handling in get_cached_token().
#
# Regression suite for the code-rotation bug: every unauthorized invocation
# minted a NEW device flow instead of reusing the pending one, so the human's
# just-authorized code was burned over and over. Two interlocking causes:
#
#   1. Token validation treated ANY `gh api user` failure (rate limit 403,
#      network error) as "token invalid" and deleted the freshly exchanged
#      token from the cache.
#   2. The mint path left a stale "${state_file}.status" == "completed"
#      marker behind; the next invocation consumed it, found no cache token,
#      and fell through to mint again — rotating the still-pending flow.
#
# All tests are hermetic: a fake gh (AI_ALIGNED_GH_BIN) plays GitHub, a fake
# curl on PATH plays the as-a-bot broker, and each test gets a fresh HOME.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$SCRIPT_DIR/executable_gh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR=$(mktemp -d)
# Mint tests spawn detached background pollers whose command lines reference
# $TMP_DIR paths; kill only those (never the user's real wrapper pollers).
trap 'pkill -f "$TMP_DIR" 2>/dev/null; rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

# --- Fake gh -----------------------------------------------------------------
# `api user` behavior is driven by $FAKE_BROKER_DIR/gh_api_user_mode:
#   ok (default)  -> HTTP 200, token accepted
#   rate_limited  -> the exact failure mode observed live: a valid token that
#                    cannot be verified because the user's primary rate limit
#                    is exhausted (HTTP 403)
#   unauthorized  -> HTTP 401, token is definitively dead
cat > "$FAKE_BIN/gh" <<'FAKEGH'
#!/bin/bash
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
    mode=$(cat "$FAKE_BROKER_DIR/gh_api_user_mode" 2>/dev/null || echo ok)
    case "$mode" in
        ok) echo '{"login":"testuser"}'; exit 0 ;;
        rate_limited)
            echo "gh: API rate limit exceeded for user ID 12345. (HTTP 403)" >&2
            exit 1 ;;
        unauthorized)
            echo "gh: Bad credentials (HTTP 401)" >&2
            exit 1 ;;
    esac
fi
if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
    echo "ghp_PERSONAL_TOKEN"
    exit 0
fi
if [ "$1" = "api" ]; then
    echo '{}'
    exit 0
fi
exit 0
FAKEGH
chmod +x "$FAKE_BIN/gh"

# --- Fake curl (the as-a-bot broker) -----------------------------------------
# /user-token/start: mints flow N -> user_code MINT-N, counts mints in
#   $FAKE_BROKER_DIR/start_count so tests can assert "no rotation happened".
# /user-token/poll:  replays $FAKE_BROKER_DIR/poll_response (default:
#   authorization_pending) and logs each polled payload to poll_log.
cat > "$FAKE_BIN/curl" <<'FAKECURL'
#!/bin/bash
url=""
prev=""
for a in "$@"; do
    case "$a" in
        http://*|https://*) url="$a" ;;
    esac
    if [ "$prev" = "-d" ]; then
        payload="$a"
    fi
    prev="$a"
done
case "$url" in
    */user-token/start)
        n=$(cat "$FAKE_BROKER_DIR/start_count" 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" > "$FAKE_BROKER_DIR/start_count"
        printf '{"device_code":"minted-devcode-%s","user_code":"MINT-%s","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}\n' "$n" "$n"
        ;;
    */user-token/poll)
        echo "${payload:-}" >> "$FAKE_BROKER_DIR/poll_log"
        cat "$FAKE_BROKER_DIR/poll_response" 2>/dev/null || echo '{"error":"authorization_pending"}'
        ;;
    *)
        echo '{}'
        ;;
esac
FAKECURL
chmod +x "$FAKE_BIN/curl"

# --- Per-test environment ----------------------------------------------------
TESTN=0
ISOLATED_HOME=""
BROKER_DIR=""
CACHE_FILE=""
STATE_FILE=""

new_env() {
    TESTN=$((TESTN + 1))
    ISOLATED_HOME="$TMP_DIR/home-$TESTN"
    BROKER_DIR="$TMP_DIR/broker-$TESTN"
    mkdir -p "$ISOLATED_HOME/.cache/ai-aligned-gh" \
        "$ISOLATED_HOME/.config/ai-aligned-gh/auth" \
        "$BROKER_DIR"
    CACHE_FILE="$ISOLATED_HOME/.cache/ai-aligned-gh/token"
    STATE_FILE="$ISOLATED_HOME/.config/ai-aligned-gh/auth/device_flow.json"
}

seed_pending_flow() { # $1 = device_code, $2 = user_code, $3 = expires_in (default 900)
    printf '{"device_code":"%s","user_code":"%s","verification_uri":"https://github.com/login/device","expires_in":%s,"interval":1}\n' \
        "$1" "$2" "${3:-900}" > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

age_state_file() { # $1 = seconds to push the state file into the past
    perl -e 'my $t = time - $ARGV[1]; utime($t, $t, $ARGV[0]) or die "utime: $!"' \
        "$STATE_FILE" "$1"
}

start_count() {
    cat "$BROKER_DIR/start_count" 2>/dev/null || echo 0
}

# AI detected (DROID_CLI=1), fake gh, fake curl as broker. The broker URL is
# a non-resolvable sentinel: only the fake curl ever sees it.
run_ai() {
    env -i \
        HOME="$ISOLATED_HOME" \
        PATH="$FAKE_BIN:/opt/homebrew/bin:/usr/bin:/bin" \
        AI_ALIGNED_GH_BIN="$FAKE_BIN/gh" \
        AS_A_BOT_URL="http://fake-broker.invalid" \
        FAKE_BROKER_DIR="$BROKER_DIR" \
        DROID_CLI=1 \
        bash "$WRAPPER" "$@"
}

echo "=== Integration: device flow reuse (no code rotation) ==="

# -----------------------------------------------------------------------------
echo ""
echo "--- Pending flow is reused, not rotated ---"
new_env
seed_pending_flow "devcode-pending" "AAAA-1111"
err=$(run_ai auth token 2>&1 >/dev/null)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -q "AAAA-1111"; then
    pass "existing user code is shown again"
else
    fail "expected existing code AAAA-1111 in output, got rc=$rc: $err"
fi
if [ "$(start_count)" = "0" ]; then
    pass "no new flow was minted"
else
    fail "a pending flow was rotated ($(start_count) mint(s))"
fi
if grep -q "devcode-pending" "$STATE_FILE" 2>/dev/null; then
    pass "pending state file is untouched"
else
    fail "pending state file was replaced or removed"
fi

# -----------------------------------------------------------------------------
echo ""
echo "--- Stale 'completed' marker next to a pending flow: still no rotation ---"
# The mint path used to leave device_flow.json.status == "completed" behind
# from an earlier flow. With no cache token, the old code consumed the marker
# and minted a brand-new flow, burning the pending code.
new_env
seed_pending_flow "devcode-pending2" "BBBB-2222"
echo "completed" > "$STATE_FILE.status"
err=$(run_ai auth token 2>&1 >/dev/null)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -q "BBBB-2222"; then
    pass "pending code survives a stale completed marker"
else
    fail "expected pending code BBBB-2222, got rc=$rc: $err"
fi
if [ "$(start_count)" = "0" ]; then
    pass "stale completed marker does not trigger a mint"
else
    fail "stale completed marker rotated the pending flow ($(start_count) mint(s))"
fi

# -----------------------------------------------------------------------------
echo ""
echo "--- Completed exchange + rate-limited validation: token is picked up ---"
# The background poller stored the token and wrote "completed"; the user's
# primary rate limit is exhausted so `gh api user` returns HTTP 403. The
# token must be returned, not deleted.
new_env
printf 'ghu_EXCHANGED_TOKEN' > "$CACHE_FILE"
chmod 600 "$CACHE_FILE"
echo "completed" > "$STATE_FILE.status"   # poller already removed $STATE_FILE
echo "rate_limited" > "$BROKER_DIR/gh_api_user_mode"
out=$(run_ai auth token 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "ghu_EXCHANGED_TOKEN" ]; then
    pass "rate-limited token is still returned"
else
    fail "expected ghu_EXCHANGED_TOKEN rc=0, got '$out' rc=$rc"
fi
if [ -f "$CACHE_FILE" ]; then
    pass "cached token survives a rate-limited validation"
else
    fail "cached token was deleted on a rate-limited validation"
fi
if [ ! -f "$STATE_FILE.status" ]; then
    pass "completed marker is consumed"
else
    fail "completed marker was left behind"
fi
if [ "$(start_count)" = "0" ]; then
    pass "no flow is minted while a usable token exists"
else
    fail "a usable token was discarded and a flow minted ($(start_count) mint(s))"
fi

# -----------------------------------------------------------------------------
echo ""
echo "--- Completed exchange + valid token: token is picked up ---"
new_env
printf 'ghu_VALID_TOKEN' > "$CACHE_FILE"
chmod 600 "$CACHE_FILE"
echo "completed" > "$STATE_FILE.status"
out=$(run_ai auth token 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "ghu_VALID_TOKEN" ]; then
    pass "completed exchange yields the token on the next invocation"
else
    fail "expected ghu_VALID_TOKEN rc=0, got '$out' rc=$rc"
fi

# -----------------------------------------------------------------------------
echo ""
echo "--- HTTP 401 still invalidates the cached token ---"
new_env
printf 'ghu_DEAD_TOKEN' > "$CACHE_FILE"
chmod 600 "$CACHE_FILE"
echo "unauthorized" > "$BROKER_DIR/gh_api_user_mode"
out=$(run_ai auth token 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ] && [ ! -f "$CACHE_FILE" ]; then
    pass "definitively dead token is removed"
else
    fail "expected 401 token removal, got '$out' rc=$rc cache_present=$([ -f "$CACHE_FILE" ] && echo yes || echo no)"
fi
if [ "$(start_count)" = "1" ]; then
    pass "a fresh flow is minted after a 401"
else
    fail "expected exactly one mint after 401, got $(start_count)"
fi

# -----------------------------------------------------------------------------
echo ""
echo "--- Already-authorized pending flow: foreground poll picks up the token ---"
new_env
seed_pending_flow "devcode-authorized" "CCCC-3333"
echo '{"access_token":"ghu_FOREGROUND_PICKUP","token_type":"bearer"}' > "$BROKER_DIR/poll_response"
out=$(run_ai auth token 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "ghu_FOREGROUND_PICKUP" ]; then
    pass "authorized flow yields a token immediately"
else
    fail "expected ghu_FOREGROUND_PICKUP rc=0, got '$out' rc=$rc"
fi
if grep -q "devcode-authorized" "$BROKER_DIR/poll_log" 2>/dev/null; then
    pass "the EXISTING device code was polled"
else
    fail "the pending device code was never polled"
fi
if [ ! -f "$STATE_FILE" ]; then
    pass "state file is cleaned up after pickup"
else
    fail "state file left behind after pickup"
fi
if [ "$(start_count)" = "0" ]; then
    pass "no rotation on pickup"
else
    fail "pickup minted a new flow ($(start_count) mint(s))"
fi

# -----------------------------------------------------------------------------
echo ""
echo "--- Denied flow is replaced by a fresh mint ---"
new_env
seed_pending_flow "devcode-denied" "DDDD-4444"
echo '{"error":"access_denied"}' > "$BROKER_DIR/poll_response"
err=$(run_ai auth token 2>&1 >/dev/null)
rc=$?
if [ "$rc" -ne 0 ] && [ "$(start_count)" = "1" ]; then
    pass "denied flow triggers exactly one new mint"
else
    fail "expected one mint after denial, got $(start_count) rc=$rc"
fi
if echo "$err" | grep -q "MINT-1"; then
    pass "the NEW code is shown after denial"
else
    fail "new code not shown after denial: $err"
fi

# -----------------------------------------------------------------------------
echo ""
echo "--- Flow expired per its own expires_in is re-minted ---"
# expires_in 300, aged 400s: younger than the old hardcoded 900s cutoff, but
# already dead at GitHub — keeping it would show a code that can never work.
new_env
seed_pending_flow "devcode-shortlived" "EEEE-5555" 300
age_state_file 400
err=$(run_ai auth token 2>&1 >/dev/null)
rc=$?
if [ "$(start_count)" = "1" ] && echo "$err" | grep -q "MINT-1"; then
    pass "expired flow (per expires_in) is replaced"
else
    fail "expected re-mint of expired flow, got $(start_count) mint(s): $err"
fi
if echo "$err" | grep -q "EEEE-5555"; then
    fail "dead code EEEE-5555 was shown to the user"
else
    pass "dead code is not shown"
fi

# -----------------------------------------------------------------------------
echo ""
echo "--- Flow older than the default 900s is re-minted ---"
new_env
seed_pending_flow "devcode-ancient" "FFFF-6666"
age_state_file 1000
err=$(run_ai auth token 2>&1 >/dev/null)
rc=$?
if [ "$(start_count)" = "1" ] && echo "$err" | grep -q "MINT-1"; then
    pass "ancient flow is replaced"
else
    fail "expected re-mint of ancient flow, got $(start_count) mint(s): $err"
fi

# -----------------------------------------------------------------------------
echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0

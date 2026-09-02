#!/bin/bash

# Tests for `gh allow-agent` (command allowlist) and matching/bypass behavior.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$SCRIPT_DIR/executable_gh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Isolated HOME so we never touch the real allowlist.
HOME=$(mktemp -d)
export HOME
ALLOW_FILE="$HOME/.config/ai-aligned-gh/allowcommands"
trap 'rm -rf "$HOME" "$TMP_DIR"' EXIT

TMP_DIR=$(mktemp -d)

echo "=== gh allow-agent CLI ==="
echo ""

# --- CLI: empty list ---
output=$("$WRAPPER" allow-agent --list 2>&1)
if echo "$output" | grep -q "No commands in allowlist"; then
    pass "--list shows empty message"
else
    fail "--list did not show empty message. Got: $output"
fi

output=$("$WRAPPER" allow-agent 2>&1)
if echo "$output" | grep -q "No commands in allowlist"; then
    pass "no args shows empty message"
else
    fail "no args did not show empty message. Got: $output"
fi

output=$("$WRAPPER" allow-agent --help 2>&1)
if echo "$output" | grep -q "gh allow-agent pr merge --auto"; then
    pass "--help prints usage with merge-queue example"
else
    fail "--help did not print usage. Got: $output"
fi

# --- CLI: add ---
output=$("$WRAPPER" allow-agent pr merge --auto 2>&1)
if echo "$output" | grep -q "Added 'pr merge --auto'"; then
    pass "add prints confirmation"
else
    fail "add did not print confirmation. Got: $output"
fi
if [ -f "$ALLOW_FILE" ] && grep -qxF "pr merge --auto" "$ALLOW_FILE"; then
    pass "entry written to allowcommands file"
else
    fail "entry not found in allowcommands file"
fi

output=$("$WRAPPER" allow-agent --list 2>&1)
if echo "$output" | grep -q "pr merge --auto"; then
    pass "--list shows added entry"
else
    fail "--list did not show entry. Got: $output"
fi

output=$("$WRAPPER" allow-agent pr merge --auto 2>&1)
if echo "$output" | grep -q "already in the allowlist"; then
    pass "duplicate add is idempotent"
else
    fail "duplicate add was not idempotent. Got: $output"
fi
count=$(grep -cxF "pr merge --auto" "$ALLOW_FILE")
if [ "$count" -eq 1 ]; then
    pass "no duplicate line in file"
else
    fail "file has $count copies of the entry (expected 1)"
fi

# --- CLI: validation ---
output=$("$WRAPPER" allow-agent pr 2>&1) && rc=$? || rc=$?
if [ "$rc" -ne 0 ] && echo "$output" | grep -q "too broad"; then
    pass "single-token write command rejected as too broad"
else
    fail "expected rejection of 'pr'. rc=$rc, output: $output"
fi

output=$("$WRAPPER" allow-agent api graphql 2>&1) && rc=$? || rc=$?
if [ "$rc" -ne 0 ] && echo "$output" | grep -q "too broad"; then
    pass "api graphql rejected as too broad"
else
    fail "expected rejection of 'api graphql'. rc=$rc, output: $output"
fi

output=$("$WRAPPER" allow-agent auth token 2>&1) && rc=$? || rc=$?
if [ "$rc" -ne 0 ] && echo "$output" | grep -q "Cannot allowlist 'auth token'"; then
    pass "auth token rejected"
else
    fail "expected rejection of 'auth token'. rc=$rc, output: $output"
fi

output=$("$WRAPPER" allow-agent --auto 2>&1) && rc=$? || rc=$?
if [ "$rc" -ne 0 ] && echo "$output" | grep -q "not only flags"; then
    pass "flags-only pattern rejected"
else
    fail "expected rejection of flags-only pattern. rc=$rc, output: $output"
fi

# A specific REST endpoint is allowed (not graphql).
output=$("$WRAPPER" allow-agent api repos/owner/repo/pulls/1/merge 2>&1)
if echo "$output" | grep -q "Added 'api repos/owner/repo/pulls/1/merge'"; then
    pass "specific REST api endpoint accepted"
else
    fail "specific REST api endpoint not accepted. Got: $output"
fi

# --- CLI: remove ---
output=$("$WRAPPER" allow-agent --remove pr merge --auto 2>&1)
if echo "$output" | grep -q "Removed 'pr merge --auto'"; then
    pass "remove prints confirmation"
else
    fail "remove did not print confirmation. Got: $output"
fi
if grep -qxF "pr merge --auto" "$ALLOW_FILE" 2>/dev/null; then
    fail "entry still in file after remove"
else
    pass "entry removed from file"
fi
if grep -qxF "api repos/owner/repo/pulls/1/merge" "$ALLOW_FILE" 2>/dev/null; then
    pass "other entries preserved after remove"
else
    fail "other entries lost after remove"
fi

output=$("$WRAPPER" allow-agent --remove nonexistent cmd 2>&1) && rc=$? || rc=$?
if [ "$rc" -ne 0 ] && echo "$output" | grep -q "is not in the allowlist"; then
    pass "remove of non-existent entry fails"
else
    fail "expected failure for non-existent remove. rc=$rc, output: $output"
fi

output=$("$WRAPPER" allow-agent --remove 2>&1) && rc=$? || rc=$?
if [ "$rc" -ne 0 ] && echo "$output" | grep -q "Usage: gh allow-agent --remove"; then
    pass "remove without a pattern prints usage"
else
    fail "expected usage for empty remove. rc=$rc, output: $output"
fi

echo ""
echo "=== command_matches_allow_pattern() ==="
echo ""

DEBUG="${DEBUG:-false}"
eval "$(sed -n '/^debug_log()/,/^}/p' "$WRAPPER")"
eval "$(sed -n '/^# --- BEGIN command allowlist ---/,/^# --- END command allowlist ---/p' "$WRAPPER")"

assert_match() {
    local description="$1"
    local pattern="$2"
    shift 2
    if command_matches_allow_pattern "$pattern" "$@"; then
        pass "$description (match)"
    else
        fail "$description — expected match"
    fi
}

assert_no_match() {
    local description="$1"
    local pattern="$2"
    shift 2
    if command_matches_allow_pattern "$pattern" "$@"; then
        fail "$description — expected no match"
    else
        pass "$description (no match)"
    fi
}

assert_match "pr merge --auto matches merge-queue invocation" \
    "pr merge --auto" pr merge 42 --auto
assert_match "pr merge --auto matches with extra flags and --repo" \
    "pr merge --auto" --repo owner/repo pr merge 42 --squash --auto
assert_match "pr merge --auto matches -R form" \
    "pr merge --auto" -R owner/repo pr merge 99 --auto
assert_match "pr merge without required flag still matches looser pattern" \
    "pr merge" pr merge 42 --squash
assert_match "pattern is a subsequence, so a PR number in between is fine" \
    "pr merge" pr merge 123
assert_no_match "pr merge --auto does not match merge without --auto" \
    "pr merge --auto" pr merge 42 --squash
assert_no_match "pr merge does not match pr create" \
    "pr merge" pr create --title hi --body there
assert_no_match "pr merge does not match issue close" \
    "pr merge" issue close 7
assert_no_match "empty pattern never matches" \
    "" pr merge --auto
assert_no_match "flags-only pattern never matches" \
    "--auto" pr merge 42 --auto

# is_allowlisted_operation reads the file
mkdir -p "$(dirname "$ALLOW_FILE")"
printf '%s\n' '# comment' '' 'pr merge --auto' > "$ALLOW_FILE"

if is_allowlisted_operation pr merge 12 --auto; then
    pass "is_allowlisted_operation matches file pattern"
else
    fail "is_allowlisted_operation should match pr merge --auto"
fi
if is_allowlisted_operation pr create --title x --body y; then
    fail "is_allowlisted_operation should not match pr create"
else
    pass "is_allowlisted_operation ignores non-matching writes"
fi
if is_allowlisted_operation pr merge 12; then
    fail "is_allowlisted_operation should require --auto from the file pattern"
else
    pass "is_allowlisted_operation honors required flags from the file"
fi

rm -f "$ALLOW_FILE"
if is_allowlisted_operation pr merge 12 --auto; then
    fail "missing allowlist file should not match"
else
    pass "missing allowlist file is a non-match"
fi

# Hand-edited too-broad lines must not match even if they are in the file.
printf '%s\n' 'pr' 'api graphql' 'auth token' > "$ALLOW_FILE"
if is_allowlisted_operation pr merge 12 --auto; then
    fail "hand-edited 'pr' pattern should be ignored"
else
    pass "hand-edited too-broad 'pr' pattern is ignored"
fi
if is_allowlisted_operation api graphql -f 'query=mutation{x}'; then
    fail "hand-edited 'api graphql' pattern should be ignored"
else
    pass "hand-edited 'api graphql' pattern is ignored"
fi
if is_allowlisted_operation auth token; then
    fail "hand-edited 'auth token' pattern should be ignored"
else
    pass "hand-edited 'auth token' pattern is ignored"
fi
rm -f "$ALLOW_FILE"

echo ""
echo "=== Integration: allowlisted writes skip token exchange ==="
echo ""

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gh" <<'EOF'
#!/bin/bash
# Record the invocation and which token was in the environment.
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
    echo "owner/repo"
    exit 0
fi
if [ -n "${GH_TOKEN:-}" ]; then
    echo "GH_TOKEN=$GH_TOKEN"
fi
echo "FAKE_GH_RAN"
exit 0
EOF
chmod +x "$FAKE_BIN/gh"

FAKE_GH_LOG="$TMP_DIR/gh.log"
export FAKE_GH_LOG
: > "$FAKE_GH_LOG"

run_ai() {
    env -i \
        HOME="$HOME" \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
        AI_ALIGNED_GH_BIN="$FAKE_BIN/gh" \
        AS_A_BOT_URL="http://127.0.0.1:9" \
        FAKE_GH_LOG="$FAKE_GH_LOG" \
        DROID_CLI=1 \
        GH_AI_DEBUG=true \
        bash "$WRAPPER" "$@"
}

mkdir -p "$HOME/.config/ai-aligned-gh"
printf '%s\n' 'pr merge --auto' > "$ALLOW_FILE"
: > "$FAKE_GH_LOG"

out=$(run_ai pr merge 42 --auto 2>&1) && rc=$? || rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "FAKE_GH_RAN"; then
    pass "allowlisted pr merge --auto reaches real gh"
else
    fail "allowlisted pr merge --auto did not reach real gh. rc=$rc output: $out"
fi
if echo "$out" | grep -q "Allowlisted operation, skipping token exchange"; then
    pass "debug log records allowlist bypass"
else
    fail "missing allowlist bypass debug log. output: $out"
fi
if echo "$out" | grep -q "Authentication required"; then
    fail "allowlisted command still demanded as-a-bot auth"
else
    pass "allowlisted command did not demand as-a-bot auth"
fi
if echo "$out" | grep -q "GH_TOKEN="; then
    fail "allowlisted command exported a bot GH_TOKEN"
else
    pass "allowlisted command did not export a bot GH_TOKEN"
fi

# Same command without --auto is not allowlisted and must not skip exchange.
: > "$FAKE_GH_LOG"
out=$(run_ai pr merge 42 --squash 2>&1) && rc=$? || rc=$?
if echo "$out" | grep -q "Allowlisted operation, skipping token exchange"; then
    fail "pr merge without --auto was treated as allowlisted"
else
    pass "pr merge without --auto is not allowlisted"
fi
if echo "$out" | grep -qE "Authentication required|Repository Required"; then
    pass "non-allowlisted write still requires as-a-bot auth"
else
    fail "non-allowlisted write did not require auth. rc=$rc output: $out"
fi

# Empty allowlist: writes stay gated.
rm -f "$ALLOW_FILE"
out=$(run_ai pr merge 42 --auto 2>&1) && rc=$? || rc=$?
if echo "$out" | grep -q "Allowlisted operation, skipping token exchange"; then
    fail "empty allowlist still bypassed token exchange"
else
    pass "empty allowlist does not bypass token exchange"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0

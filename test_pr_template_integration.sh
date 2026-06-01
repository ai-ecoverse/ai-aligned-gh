#!/bin/bash

# Integration test for the PR template safeguard. Uses a fake `gh` binary
# to avoid real network calls and isolates HOME / cache.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$SCRIPT_DIR/executable_gh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Build an isolated environment.
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

# Fake gh: handles the calls our wrapper makes, prints stable JSON, and
# exits 0. Anything else is a no-op success.
cat > "$FAKE_BIN/gh" <<'EOF'
#!/bin/bash
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
    # gh repo view --json nameWithOwner --jq '.nameWithOwner'
    echo "fakeowner/fakerepo"
    exit 0
fi
if [ "$1" = "api" ]; then
    # Accept any API call silently
    echo '{}'
    exit 0
fi
# Pretend any other command succeeded.
exit 0
EOF
chmod +x "$FAKE_BIN/gh"

# Set up isolated HOME so cache writes happen in TMP_DIR.
ISOLATED_HOME="$TMP_DIR/home"
mkdir -p "$ISOLATED_HOME"

run_wrapper() {
    # Place fake gh first in PATH so find_real_gh picks it up. Mark Droid
    # as the active AI tool so the safeguard is triggered.
    env -i \
        HOME="$ISOLATED_HOME" \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
        DROID_CLI=1 \
        bash "$WRAPPER" "$@"
}

cache_file_for() {
    echo "$ISOLATED_HOME/.cache/ai-aligned-gh/pr-template-checks/${1}__${2}"
}

REPO_FLAG_OWNER="fakeowner"
REPO_FLAG_REPO="fakerepo"
REPO_SPEC="${REPO_FLAG_OWNER}/${REPO_FLAG_REPO}"

echo "=== Integration: gh pr create rejected before template check ==="
output=$(run_wrapper --repo "$REPO_SPEC" pr create --title hi --body world 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$output" | grep -q "PR Template Check Required"; then
    pass "pr create rejected with safeguard message"
else
    fail "expected rejection, got rc=$rc, output: $output"
fi

echo ""
echo "=== Integration: gh api PULL_REQUEST_TEMPLATE records cache ==="
run_wrapper api "repos/${REPO_FLAG_OWNER}/${REPO_FLAG_REPO}/contents/.github/PULL_REQUEST_TEMPLATE" >/dev/null 2>&1 || true
cache_path=$(cache_file_for "$REPO_FLAG_OWNER" "$REPO_FLAG_REPO")
if [ -f "$cache_path" ]; then
    pass "cache file created after gh api call"
else
    fail "expected cache file at $cache_path"
fi

echo ""
echo "=== Integration: gh pr create allowed after recent check ==="
output=$(run_wrapper --repo "$REPO_SPEC" pr create --title hi --body world 2>&1)
if echo "$output" | grep -q "PR Template Check Required"; then
    fail "pr create still rejected after template check was recorded: $output"
else
    pass "pr create not blocked by safeguard after recent check"
fi

echo ""
echo "=== Integration: per-repo isolation via --repo flag ==="
output=$(run_wrapper --repo other/proj pr create --title T --body B 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$output" | grep -q "other/proj"; then
    pass "--repo flag drives safeguard message for different repo"
else
    fail "expected rejection mentioning other/proj, rc=$rc, output: $output"
fi

# Record check for that repo via .md variant.
run_wrapper api "repos/other/proj/contents/.github/PULL_REQUEST_TEMPLATE.md" >/dev/null 2>&1 || true
output=$(run_wrapper --repo other/proj pr create --title T --body B 2>&1)
if echo "$output" | grep -q "PR Template Check Required"; then
    fail "pr create still rejected after .md endpoint check"
else
    pass ".md endpoint counts as PR template check"
fi

echo ""
echo "=== Integration: no AI detected bypasses safeguard ==="
# AMI_PASSTHROUGH=true forces am-i-ai to report "none" regardless of the
# surrounding process tree, so we can verify the safeguard is bypassed.
output=$(env -i HOME="$ISOLATED_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" \
    AMI_PASSTHROUGH=true \
    bash "$WRAPPER" --repo othernoai/nope pr create --title hi --body world 2>&1 || true)
if echo "$output" | grep -q "PR Template Check Required"; then
    fail "safeguard fired even without AI detected: $output"
else
    pass "no AI detected: safeguard bypassed"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1
exit 0

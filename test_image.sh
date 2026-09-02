#!/bin/bash

# Test script for the retired `gh image` subcommand
# Verifies the version check, both error messages, and the --attach tip shown
# on pr/issue create, using a fake gh whose reported version is configurable.

set -e

# Colors for output
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    BLUE=''
    CYAN=''
    NC=''
fi

print_test() {
    echo -e "${CYAN}[TEST]${NC} $*"
}

print_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

print_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    FAILURES=$((FAILURES + 1))
}

FAILURES=0

echo ""
echo -e "${BLUE}=== gh image retirement Test Suite ===${NC}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GH_WRAPPER="$SCRIPT_DIR/executable_gh"

# Isolated HOME + workspace with a fake gh
HOME=$(mktemp -d)
export HOME
WORK=$(mktemp -d)
trap 'rm -rf "$HOME" "$WORK"' EXIT

FAKEBIN="$WORK/bin"
STATE="$WORK/state"
mkdir -p "$FAKEBIN" "$STATE"
export FAKE_STATE="$STATE"

# Fake gh: reports whatever version the test wrote to $FAKE_STATE/version
cat > "$FAKEBIN/gh" <<'FAKE'
#!/bin/bash
if [ "$1" = "--version" ]; then
    version=$(cat "$FAKE_STATE/version" 2>/dev/null || true)
    if [ -n "$version" ]; then
        echo "gh version $version (2026-09-01)"
        echo "https://github.com/cli/cli/releases/tag/v$version"
    fi
    exit 0
fi
exit 0
FAKE
chmod +x "$FAKEBIN/gh"

set_gh_version() {
    printf '%s' "$1" > "$STATE/version"
}

run_wrapper() {
    AMI_PASSTHROUGH=true \
    AS_A_BOT_URL="https://broker.test" \
    AI_ALIGNED_GH_BIN="$FAKEBIN/gh" \
    PATH="$FAKEBIN:$PATH" \
    "$GH_WRAPPER" "$@"
}

# Runner that simulates an AI agent (Claude env var, no passthrough)
run_ai() {
    CLAUDECODE=1 \
    AS_A_BOT_URL="https://broker.test" \
    AI_ALIGNED_GH_BIN="$FAKEBIN/gh" \
    PATH="$FAKEBIN:$PATH" \
    "$GH_WRAPPER" "$@"
}

# Test 1: gh >= 2.99.0 — point at --attach
print_test "gh 2.99.0 gets the --attach message"
set_gh_version "2.99.0"
if output=$(run_wrapper image shot.png 2>&1); then
    print_fail "Expected non-zero exit for gh image"
else
    if echo "$output" | grep -q "has been retired" &&
       echo "$output" | grep -q -- "--attach ./before.png" &&
       ! echo "$output" | grep -qi "update gh"; then
        print_pass "Retired message told the caller to use --attach"
    else
        print_fail "Wrong message for gh 2.99.0. Got: $output"
    fi
fi

# Test 1b: newer versions are also recognized
print_test "gh 2.100.0 is recognized as supporting --attach"
set_gh_version "2.100.0"
if output=$(run_wrapper image shot.png 2>&1); then
    print_fail "Expected non-zero exit for gh image"
else
    if echo "$output" | grep -q -- "--attach" && ! echo "$output" | grep -qi "Update gh"; then
        print_pass "2.100.0 compared greater than 2.99.0"
    else
        print_fail "2.100.0 misread as older. Got: $output"
    fi
fi

print_test "gh 3.0.0 is recognized as supporting --attach"
set_gh_version "3.0.0"
if output=$(run_wrapper image shot.png 2>&1); then
    print_fail "Expected non-zero exit for gh image"
else
    if echo "$output" | grep -q -- "--attach" && ! echo "$output" | grep -qi "Update gh"; then
        print_pass "3.0.0 compared greater than 2.99.0"
    else
        print_fail "3.0.0 misread as older. Got: $output"
    fi
fi

# Test 2: gh < 2.99.0 — tell the caller to update first
print_test "gh 2.98.0 is told to update, then use --attach"
set_gh_version "2.98.0"
if output=$(run_wrapper image shot.png 2>&1); then
    print_fail "Expected non-zero exit for gh image"
else
    if echo "$output" | grep -q "has been retired" &&
       echo "$output" | grep -q "Update gh" &&
       echo "$output" | grep -q "You have gh 2.98.0" &&
       echo "$output" | grep -q -- "--attach ./before.png"; then
        print_pass "Older gh got the update-then-attach message"
    else
        print_fail "Wrong message for gh 2.98.0. Got: $output"
    fi
fi

# Test 3: unknown version is treated as too old
print_test "Undetectable gh version is treated as too old"
set_gh_version ""
if output=$(run_wrapper image shot.png 2>&1); then
    print_fail "Expected non-zero exit for gh image"
else
    if echo "$output" | grep -q "could not" && echo "$output" | grep -q "Update gh"; then
        print_pass "Unknown version got the update message"
    else
        print_fail "Wrong message for unknown version. Got: $output"
    fi
fi

# Test 4: no upload happens — nothing is printed on stdout
print_test "gh image prints nothing on stdout"
set_gh_version "2.99.0"
output=$(run_wrapper image shot.png 2>/dev/null || true)
if [ -z "$output" ]; then
    print_pass "stdout stayed empty"
else
    print_fail "Expected empty stdout. Got: $output"
fi

# Test 5: AI agents get the --attach tip on pr create
print_test "gh pr create shows the --attach tip for AI agents"
set_gh_version "2.99.0"
output=$(run_ai pr create --repo testowner/testrepo --title t --body b 2>&1 || true)
if echo "$output" | grep -q -- "--attach ./shot.png"; then
    print_pass "pr create surfaced the --attach tip"
else
    print_fail "pr create did not surface the tip. Got: $output"
fi

# Test 6: AI agents get the --attach tip on issue create
print_test "gh issue create shows the --attach tip for AI agents"
output=$(run_ai issue create --repo testowner/testrepo --title t --body b 2>&1 || true)
if echo "$output" | grep -q -- "--attach ./shot.png"; then
    print_pass "issue create surfaced the --attach tip"
else
    print_fail "issue create did not surface the tip. Got: $output"
fi

# Test 7: on older gh the tip asks for an update instead
print_test "Old gh turns the tip into an update hint"
set_gh_version "2.98.0"
output=$(run_ai pr create --repo testowner/testrepo --title t --body b 2>&1 || true)
if echo "$output" | grep -q "2.99.0 or newer" && ! echo "$output" | grep -q -- "--attach ./shot.png"; then
    print_pass "Old gh got the update hint"
else
    print_fail "Old gh tip wrong. Got: $output"
fi

# Test 8: read-only commands do not get the tip
print_test "gh pr list does not show the tip"
set_gh_version "2.99.0"
output=$(run_ai pr list 2>&1 || true)
if echo "$output" | grep -qi "attach"; then
    print_fail "pr list unexpectedly surfaced the tip. Got: $output"
else
    print_pass "pr list stayed quiet"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}All gh image retirement tests passed!${NC}"
    exit 0
else
    echo -e "${RED}$FAILURES gh image retirement test(s) failed${NC}"
    exit 1
fi

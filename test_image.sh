#!/bin/bash

# Test script for the `gh image` subcommand
# Verifies help, argument validation, content-addressed dedupe, and the
# full dispatch → poll → upload → verify flow using fake curl/gh binaries.

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

print_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

FAILURES=0

echo ""
echo -e "${BLUE}=== gh image Test Suite ===${NC}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GH_WRAPPER="$SCRIPT_DIR/executable_gh"

# Isolated HOME + workspace with fake binaries
HOME=$(mktemp -d)
export HOME
WORK=$(mktemp -d)
trap 'rm -rf "$HOME" "$WORK"' EXIT

FAKEBIN="$WORK/bin"
STATE="$WORK/state"
mkdir -p "$FAKEBIN" "$STATE"
export FAKE_STATE="$STATE"

# Fake curl: simulates the as-a-bot worker + R2
cat > "$FAKEBIN/curl" <<'FAKE'
#!/bin/bash
args="$*"
case "$args" in
    *image-upload/status*)
        if [ -f "$FAKE_STATE/pending" ]; then
            echo '{"status":"pending"}'
        else
            checksum=$(cat "$FAKE_STATE/checksum" 2>/dev/null || echo "unset")
            echo "{\"status\":\"ready\",\"upload_url\":\"https://acc.r2.cloudflarestorage.com/bucket/key?sig=1\",\"upload_headers\":{\"x-amz-checksum-sha256\":\"$checksum\"}}"
        fi
        exit 0
        ;;
esac
if echo "$args" | grep -q "PUT"; then
    echo "$args" > "$FAKE_STATE/put_args"
    exit 0
fi
# HEAD probe (dedupe before upload, verification after)
if echo "$args" | grep -q -- "-sfI"; then
    if [ -f "$FAKE_STATE/head_ok" ] || [ -f "$FAKE_STATE/put_args" ]; then
        exit 0
    fi
    exit 22
fi
exit 0
FAKE
chmod +x "$FAKEBIN/curl"

# Fake gh: records workflow dispatches
cat > "$FAKEBIN/gh" <<'FAKE'
#!/bin/bash
if [ "$1" = "workflow" ] && [ "$2" = "run" ]; then
    echo "$@" > "$FAKE_STATE/workflow_args"
    exit 0
fi
exit 0
FAKE
chmod +x "$FAKEBIN/gh"

run_image() {
    AMI_PASSTHROUGH=true \
    AS_A_BOT_URL="https://broker.test" \
    AI_ALIGNED_GH_BIN="$FAKEBIN/gh" \
    PATH="$FAKEBIN:$PATH" \
    "$GH_WRAPPER" image "$@"
}

# Hex-to-base64 with the same fallbacks the wrapper uses
hex_to_b64() {
    if command -v xxd >/dev/null 2>&1; then
        printf '%s' "$1" | xxd -r -p | base64 | tr -d '\n'
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys, base64, binascii; print(base64.b64encode(binascii.unhexlify(sys.argv[1])).decode())' "$1"
    else
        perl -MMIME::Base64 -e 'print encode_base64(pack("H*", $ARGV[0]), "")' "$1"
    fi
}

# Test fixture: a small "png"
TEST_FILE="$WORK/shot.png"
printf 'not-really-a-png' > "$TEST_FILE"
HASH=$(sha256sum "$TEST_FILE" | awk '{print $1}')
HASH_B64=$(hex_to_b64 "$HASH")
if [ -z "$HASH_B64" ]; then
    echo "Could not compute base64 checksum (need xxd, python3, or perl)" >&2
    exit 1
fi
SERVE_URL="https://broker.test/i/testowner/testrepo/$HASH.png"

# Test 1: --help prints usage
print_test "--help prints usage"
output=$(run_image --help 2>&1)
if echo "$output" | grep -q "USAGE" && echo "$output" | grep -q "gh image <file>"; then
    print_pass "--help shows usage"
else
    print_fail "--help did not show usage. Got: $output"
fi

# Test 2: no arguments fails with usage
print_test "No arguments fails with usage"
if output=$(run_image 2>&1); then
    print_fail "Expected non-zero exit for missing file"
else
    if echo "$output" | grep -q "USAGE"; then
        print_pass "Missing file shows usage and fails"
    else
        print_fail "Missing file did not show usage. Got: $output"
    fi
fi

# Test 3: nonexistent file fails
print_test "Nonexistent file fails"
if output=$(run_image /does/not/exist.png 2>&1); then
    print_fail "Expected non-zero exit for nonexistent file"
else
    if echo "$output" | grep -q "not found"; then
        print_pass "Nonexistent file rejected"
    else
        print_fail "Wrong error for nonexistent file. Got: $output"
    fi
fi

# Test 4: unsupported extension fails
print_test "Unsupported extension fails"
printf 'x' > "$WORK/evil.exe"
if output=$(run_image "$WORK/evil.exe" --repo testowner/testrepo 2>&1); then
    print_fail "Expected non-zero exit for .exe"
else
    if echo "$output" | grep -q "unsupported file type"; then
        print_pass ".exe rejected"
    else
        print_fail "Wrong error for .exe. Got: $output"
    fi
fi

# Test 5: file without extension fails
print_test "File without extension fails"
printf 'x' > "$WORK/noext"
if output=$(run_image "$WORK/noext" --repo testowner/testrepo 2>&1); then
    print_fail "Expected non-zero exit for extensionless file"
else
    if echo "$output" | grep -q "no extension"; then
        print_pass "Extensionless file rejected"
    else
        print_fail "Wrong error for extensionless file. Got: $output"
    fi
fi

# Test 6: content-addressed dedupe returns URL without dispatching
print_test "Dedupe: already-uploaded content returns URL immediately"
touch "$STATE/head_ok"
output=$(run_image "$TEST_FILE" --repo testowner/testrepo 2>/dev/null)
if [ "$output" = "$SERVE_URL" ]; then
    print_pass "Dedupe returned the content-addressed URL"
else
    print_fail "Dedupe URL mismatch. Expected: $SERVE_URL Got: $output"
fi
if [ ! -f "$STATE/workflow_args" ]; then
    print_pass "Dedupe did not dispatch the workflow"
else
    print_fail "Dedupe dispatched the workflow unexpectedly"
fi
rm -f "$STATE/head_ok"

# Test 7: full flow — dispatch, poll, upload, verify
print_test "Full flow: dispatch, poll, upload, verify"
printf '%s' "$HASH_B64" > "$STATE/checksum"
output=$(run_image "$TEST_FILE" --repo testowner/testrepo 2>/dev/null)
if [ "$output" = "$SERVE_URL" ]; then
    print_pass "Full flow printed the serve URL"
else
    print_fail "Full flow URL mismatch. Expected: $SERVE_URL Got: $output"
fi
if [ -f "$STATE/workflow_args" ] && grep -q "workflow run image-upload.yml --repo testowner/testrepo -f hash=$HASH -f ext=png" "$STATE/workflow_args"; then
    print_pass "Workflow dispatched with hash and extension"
else
    print_fail "Workflow dispatch args wrong. Got: $(cat "$STATE/workflow_args" 2>/dev/null)"
fi
if [ -f "$STATE/put_args" ] && grep -q "x-amz-checksum-sha256: $HASH_B64" "$STATE/put_args"; then
    print_pass "Upload sent the checksum header from the offer"
else
    print_fail "Upload missing checksum header. Got: $(cat "$STATE/put_args" 2>/dev/null)"
fi
if grep -q "Content-Type: image/png" "$STATE/put_args" 2>/dev/null; then
    print_pass "Upload sent the right Content-Type"
else
    print_fail "Upload missing Content-Type header"
fi
rm -f "$STATE/workflow_args" "$STATE/put_args"

# Test 8: timeout when the worker never provides a URL
print_test "Timeout when the offer never arrives"
touch "$STATE/pending"
if output=$(run_image "$TEST_FILE" --repo testowner/testrepo --timeout 1 2>&1); then
    print_fail "Expected non-zero exit on timeout"
else
    if echo "$output" | grep -q "timed out"; then
        print_pass "Timed out with a helpful error"
    else
        print_fail "Wrong timeout error. Got: $output"
    fi
fi
rm -f "$STATE/pending" "$STATE/workflow_args"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}All gh image tests passed!${NC}"
    exit 0
else
    echo -e "${RED}$FAILURES gh image test(s) failed${NC}"
    exit 1
fi

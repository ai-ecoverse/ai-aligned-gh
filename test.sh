#!/bin/bash

# Test script for AI-Aligned-GH wrapper
# Verifies installation and functionality

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

FAILURES=0

print_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    FAILURES=$((FAILURES + 1))
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

echo ""
echo -e "${BLUE}=== AI-Aligned-GH Test Suite ===${NC}"
echo ""

# Test 1: Check if wrapper is installed
print_test "Checking if wrapper is installed..."
if [ -x "$HOME/.local/bin/gh" ]; then
    print_pass "Wrapper found at ~/.local/bin/gh"
else
    print_fail "Wrapper not found at ~/.local/bin/gh"
    print_info "Run ./install.sh first"
    exit 1
fi

# Test 2: Check if wrapper is in PATH
print_test "Checking if wrapper is in PATH..."
export PATH="$HOME/.local/bin:$PATH"
FIRST_GH=$(which gh 2>/dev/null)
if [ "$FIRST_GH" = "$HOME/.local/bin/gh" ]; then
    print_pass "Wrapper is first in PATH"
else
    print_fail "Wrapper is not first in PATH (found: $FIRST_GH)"
    print_info "Add ~/.local/bin to the beginning of your PATH"
fi

# Test 3: Check prerequisites
print_test "Checking prerequisites..."
if command -v jq >/dev/null 2>&1; then
    print_pass "jq is installed"
else
    print_fail "jq is not installed (recommended for token parsing)"
fi

if command -v git >/dev/null 2>&1; then
    print_pass "git is installed"
else
    print_fail "git is not installed (needed for repo detection)"
fi

# Test 4: Test AI detection
# Assert each tool's env marker triggers its per-tool am-i-ai detection line
# (AMI_DEBUG output). Matching the per-tool line instead of the final priority
# winner keeps this hermetic when the suite itself runs under an AI tool —
# ambient CLAUDECODE or a claude/codex ancestor in the process tree would
# otherwise outrank lower-priority simulated tools. Ambient markers are unset
# so each case proves its own trigger.
print_test "Testing AI detection..."
AMBIENT_AI_VARS=(-u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT
    -u CODEX_CLI -u CODEX_SANDBOX -u CODEX_SHELL -u CODEX_THREAD_ID
    -u CURSOR_AGENT -u GEMINI_CLI -u QWEN_CODE -u OPENCODE_AI -u KIMI_CLI
    -u AUGMENT_API_TOKEN -u AUGMENT_AGENT -u ZED_ENVIRONMENT -u ZED_TERM)
while IFS='|' read -r assignment tool_name pattern; do
    OUTPUT=$(env "${AMBIENT_AI_VARS[@]}" AMI_DEBUG=true GH_AI_DEBUG=true \
        "$assignment" gh --version 2>&1)
    if echo "$OUTPUT" | grep -q "$pattern"; then
        print_pass "  ✓ $tool_name detection works"
    else
        print_fail "  ✗ $tool_name detection failed"
    fi
done <<'DETECTIONS'
CLAUDECODE=1|claude|Detected Claude via environment variable
CURSOR_AGENT=1|cursor|Detected Cursor via environment variable
GEMINI_CLI=1|gemini|Detected Gemini via environment variable
QWEN_CODE=1|qwen|Detected Qwen via environment variable
OPENCODE_AI=1|opencode|Detected OpenCode via environment variable
CODEX_CLI=1|codex|Detected Codex via environment variable
KIMI_CLI=1|kimi|Detected Kimi CLI via environment variable
AUGMENT_API_TOKEN=1|auggie|Detected Auggie via environment variable
DETECTIONS

# Zed's agent heuristic additionally requires SHLVL>1, a Zed terminal marker,
# and a non-shell parent process; xargs supplies the non-shell parent.
OUTPUT=$(echo x | env "${AMBIENT_AI_VARS[@]}" AMI_DEBUG=true GH_AI_DEBUG=true \
    ZED_ENVIRONMENT=agent ZED_TERM=true SHLVL=2 xargs -I DUMMY gh --version 2>&1)
if echo "$OUTPUT" | grep -q "Detected Zed AI agent via environment"; then
    print_pass "  ✓ zed detection works"
else
    print_fail "  ✗ zed detection failed"
fi

# Test 5: Test passthrough without AI
print_test "Testing passthrough when no AI detected..."
OUTPUT=$(GH_AI_DEBUG=true gh --version 2>&1)
if echo "$OUTPUT" | grep -q "No AI detected"; then
    print_pass "Correctly passes through when no AI detected"
else
    # We might actually be running under an AI
    if echo "$OUTPUT" | grep -q "AI detected"; then
        print_info "Currently running under AI, cannot test passthrough"
    else
        print_fail "Unexpected behavior"
    fi
fi

# Test 6: Test safe (read-only) operation passthrough
print_test "Testing safe operation passthrough..."
OUTPUT=$(env GH_AI_DEBUG=true CLAUDECODE=1 gh --version 2>&1 || true)
if echo "$OUTPUT" | grep -q "Safe operation, skipping token exchange"; then
    print_pass "Safe operations correctly skip token exchange"
else
    print_fail "Safe operation did not skip token exchange"
fi

# Read-only GraphQL queries are safe operations too (the network call may
# fail without auth — only the classification matters here)
OUTPUT=$(env GH_AI_DEBUG=true CLAUDECODE=1 \
    gh api graphql -f query='query{viewer{login}}' 2>&1 || true)
if echo "$OUTPUT" | grep -q "Safe operation, skipping token exchange"; then
    print_pass "Read-only GraphQL queries skip token exchange"
else
    print_fail "Read-only GraphQL query was not classified as safe"
fi

# Test 7: Check repository detection (if in a git repo with an origin remote)
print_test "Testing repository detection..."
if git remote get-url origin >/dev/null 2>&1; then
    # shellcheck disable=SC2034  # read by the eval'd get_repo_info below
    GH_BIN="$HOME/.local/bin/gh"
    eval "$(sed -n '/^debug_log()/,/^}/p' executable_gh)"
    eval "$(sed -n '/^get_repo_info()/,/^}/p' executable_gh)"
    if read -r REPO_OWNER REPO_NAME < <(get_repo_info "") &&
        [ -n "$REPO_OWNER" ] && [ -n "$REPO_NAME" ]; then
        print_pass "Repository detection works ($REPO_OWNER/$REPO_NAME)"
    else
        print_fail "Repository detection failed"
    fi
else
    print_info "No origin remote configured, skipping repo detection test"
fi

echo ""
echo -e "${BLUE}=== Test Summary ===${NC}"
echo ""

print_info "Basic functionality tests completed"
print_info "To test token exchange with a real repository:"
echo "  1. Install the as-a-bot app: https://github.com/apps/as-a-bot"
echo "  2. Navigate to a GitHub repository with the app installed"
echo "  3. Run: GH_AI_DEBUG=true CLAUDECODE=1 gh pr create --dry-run"
echo ""

if [ "$FAILURES" -gt 0 ]; then
    echo -e "${RED}$FAILURES test(s) failed${NC}"
    echo ""
    exit 1
fi

echo -e "${GREEN}Tests completed!${NC}"
echo ""

#!/bin/bash

# Test that install.sh replaces ~/.local/bin/gh atomically (issue #67)
#
# Each case runs install.sh in a sandbox HOME with a fake source wrapper, so
# nothing touches the real installation.

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$description"
    else
        fail "$description"
    fi
}

# Creates a sandbox: $SANDBOX/home is HOME, $SANDBOX/work is the working dir
# containing an executable_gh with the given body.
make_sandbox() {
    SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ai-aligned-gh-install.XXXXXX")
    mkdir -p "$SANDBOX/home/.local/bin" "$SANDBOX/work" "$SANDBOX/bin"
    # Stub gh so check_prerequisites passes without a real gh on the machine
    printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/bin/gh"
    chmod +x "$SANDBOX/bin/gh"
    cp "$REPO_DIR/install.sh" "$SANDBOX/work/install.sh"
    printf '#!/bin/bash\n# ai-aligned-gh wrapper\necho new-wrapper\n' \
        > "$SANDBOX/work/executable_gh"
    chmod +x "$SANDBOX/work/executable_gh"
}

run_install() {
    ( cd "$SANDBOX/work" && \
      HOME="$SANDBOX/home" UPGRADE=true PATH="$SANDBOX/bin:$PATH" \
      bash ./install.sh )
}

echo "=== install.sh atomic replacement tests ==="
echo ""

# --- Fresh install ---
make_sandbox
run_install >/dev/null 2>&1
GH="$SANDBOX/home/.local/bin/gh"
assert "fresh install writes the wrapper" test -x "$GH"
assert "fresh install leaves no staging file" \
    bash -c '! ls "$1"/home/.local/bin/.gh.new.* >/dev/null 2>&1' _ "$SANDBOX"
rm -rf "$SANDBOX"

# --- Upgrade over an existing wrapper keeps a rollback backup ---
make_sandbox
GH="$SANDBOX/home/.local/bin/gh"
printf '#!/bin/bash\n# ai-aligned-gh wrapper\necho old-wrapper\n' > "$GH"
chmod +x "$GH"
run_install >/dev/null 2>&1
if grep -q new-wrapper "$GH"; then
    pass "upgrade replaces the previous wrapper"
else
    fail "upgrade replaces the previous wrapper"
fi
if grep -lq old-wrapper "$SANDBOX"/home/.local/bin/gh.backup.* 2>/dev/null; then
    pass "upgrade keeps a backup of the previous wrapper"
else
    fail "upgrade keeps a backup of the previous wrapper"
fi
rm -rf "$SANDBOX"

# --- A failed download must not touch the installed wrapper ---
# Simulate the truncation case: no local executable_gh, and curl/wget both
# unavailable, so the fetch fails before anything is staged.
make_sandbox
GH="$SANDBOX/home/.local/bin/gh"
printf '#!/bin/bash\n# ai-aligned-gh wrapper\necho old-wrapper\n' > "$GH"
chmod +x "$GH"
rm "$SANDBOX/work/executable_gh"
for c in curl wget; do
    printf '#!/bin/bash\nexit 1\n' > "$SANDBOX/bin/$c"
    chmod +x "$SANDBOX/bin/$c"
done
run_install >/dev/null 2>&1
if grep -q old-wrapper "$GH"; then
    pass "failed fetch leaves the existing wrapper intact"
else
    fail "failed fetch leaves the existing wrapper intact"
fi
assert "failed fetch leaves no staging file behind" \
    bash -c '! ls "$1"/home/.local/bin/.gh.new.* >/dev/null 2>&1' _ "$SANDBOX"
rm -rf "$SANDBOX"

# --- A truncated/corrupt source must be rejected before the swap ---
make_sandbox
GH="$SANDBOX/home/.local/bin/gh"
printf '#!/bin/bash\n# ai-aligned-gh wrapper\necho old-wrapper\n' > "$GH"
chmod +x "$GH"
printf '#!/bin/bash\n# truncated mid-dow' > "$SANDBOX/work/executable_gh"
run_install >/dev/null 2>&1
if grep -q old-wrapper "$GH"; then
    pass "truncated source is rejected, wrapper untouched"
else
    fail "truncated source is rejected, wrapper untouched"
fi
rm -rf "$SANDBOX"

# --- An empty source must be rejected before the swap ---
make_sandbox
GH="$SANDBOX/home/.local/bin/gh"
printf '#!/bin/bash\n# ai-aligned-gh wrapper\necho old-wrapper\n' > "$GH"
chmod +x "$GH"
: > "$SANDBOX/work/executable_gh"
run_install >/dev/null 2>&1
if grep -q old-wrapper "$GH"; then
    pass "empty source is rejected, wrapper untouched"
else
    fail "empty source is rejected, wrapper untouched"
fi
rm -rf "$SANDBOX"

# --- Staging happens in the target directory (same filesystem => atomic mv) ---
if grep -q 'STAGED="$INSTALL_DIR/' "$REPO_DIR/install.sh"; then
    pass "staging file lives in the install directory"
else
    fail "staging file lives in the install directory"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

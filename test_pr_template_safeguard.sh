#!/bin/bash

# Test PR template safeguard helpers from executable_gh.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXECUTABLE_GH="$SCRIPT_DIR/executable_gh"

# Pull in the helper functions without executing the main script.
extract_block() {
    local name="$1"
    sed -n "/^${name}()/,/^}/p" "$EXECUTABLE_GH"
}

eval "$(extract_block pr_template_cache_file)"
eval "$(extract_block pr_template_check_is_fresh)"
eval "$(extract_block record_pr_template_check)"
eval "$(extract_block extract_pr_template_repo_from_api_args)"
eval "$(extract_block _gh_flag_takes_value)"
eval "$(extract_block _is_create_invocation_for)"
eval "$(extract_block is_pr_create_invocation)"

# Use an isolated cache dir for the tests.
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
PR_TEMPLATE_CACHE_DIR="$TMP_DIR/cache"
PR_TEMPLATE_CACHE_TTL=3600
export PR_TEMPLATE_CACHE_DIR PR_TEMPLATE_CACHE_TTL

PASS=0
FAIL=0

pass() {
    echo "PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
}

assert_pr_create() {
    local desc="$1"; shift
    if is_pr_create_invocation "$@"; then
        pass "$desc (recognized as pr create)"
    else
        fail "$desc — expected pr create, was not recognized"
    fi
}

assert_not_pr_create() {
    local desc="$1"; shift
    if is_pr_create_invocation "$@"; then
        fail "$desc — incorrectly recognized as pr create"
    else
        pass "$desc (not pr create)"
    fi
}

assert_api_match() {
    local desc="$1"
    local expected_owner="$2"
    local expected_repo="$3"
    shift 3
    local got_owner got_repo
    if read -r got_owner got_repo < <(extract_pr_template_repo_from_api_args "$@"); then
        if [ "$got_owner" = "$expected_owner" ] && [ "$got_repo" = "$expected_repo" ]; then
            pass "$desc → $got_owner/$got_repo"
        else
            fail "$desc → got $got_owner/$got_repo, expected $expected_owner/$expected_repo"
        fi
    else
        fail "$desc → did not match (expected $expected_owner/$expected_repo)"
    fi
}

assert_api_nomatch() {
    local desc="$1"; shift
    if extract_pr_template_repo_from_api_args "$@" >/dev/null; then
        fail "$desc — unexpectedly matched"
    else
        pass "$desc (no match)"
    fi
}

echo "=== is_pr_create_invocation() ==="
assert_pr_create     "pr create"                               pr create
assert_pr_create     "pr new (alias)"                          pr new
assert_pr_create     "pr new --title T --body B"               pr new --title T --body B
assert_pr_create     "pr create --title T --body B"            pr create --title T --body B
assert_pr_create     "--repo o/r pr create"                    --repo o/r pr create
assert_pr_create     "-R o/r pr create --fill"                 -R o/r pr create --fill
assert_pr_create     "--repo=o/r pr create"                    --repo=o/r pr create
assert_pr_create     "pr -R o/r create"                        pr -R o/r create
assert_pr_create     "pr --repo o/r create"                    pr --repo o/r create
assert_pr_create     "pr --repo=o/r create"                    pr --repo=o/r create
assert_pr_create     "pr -R o/r new"                           pr -R o/r new
assert_pr_create     "--config /tmp/cfg pr create"             --config /tmp/cfg pr create
assert_pr_create     "--hostname gh.example pr create"         --hostname gh.example pr create
assert_pr_create     "pr --some-flag create"                   pr --some-flag create
assert_not_pr_create "pr list"                                 pr list
assert_not_pr_create "pr view 123"                             pr view 123
assert_not_pr_create "pr edit 1"                               pr edit 1
assert_not_pr_create "pr review --approve"                     pr review --approve
assert_not_pr_create "issue create"                            issue create
assert_not_pr_create "api repos/o/r/pulls"                     api repos/o/r/pulls
assert_not_pr_create "repo create new-repo"                    repo create new-repo
assert_not_pr_create "pr -R o/r list"                          pr -R o/r list

echo ""
echo "=== extract_pr_template_repo_from_api_args() ==="
assert_api_match    "directory endpoint"                   o   r       api repos/o/r/contents/.github/PULL_REQUEST_TEMPLATE
assert_api_match    "directory endpoint trailing slash"    o   r       api repos/o/r/contents/.github/PULL_REQUEST_TEMPLATE/
assert_api_match    "single file .md endpoint"             a   b       api repos/a/b/contents/.github/PULL_REQUEST_TEMPLATE.md
assert_api_match    "specific template inside dir"         x   y       api repos/x/y/contents/.github/PULL_REQUEST_TEMPLATE/feature.md
assert_api_match    "leading slash endpoint"               ai  gh-wrap api /repos/ai/gh-wrap/contents/.github/PULL_REQUEST_TEMPLATE
assert_api_match    "endpoint after flags"                 o   r       api --jq .name repos/o/r/contents/.github/PULL_REQUEST_TEMPLATE
assert_api_match    "endpoint with ?ref=main"              o   r       api "repos/o/r/contents/.github/PULL_REQUEST_TEMPLATE?ref=main"
assert_api_match    "endpoint .md with ?ref=main"          a   b       api "repos/a/b/contents/.github/PULL_REQUEST_TEMPLATE.md?ref=main"
assert_api_match    "endpoint dir trailing slash + query"  o   r       api "repos/o/r/contents/.github/PULL_REQUEST_TEMPLATE/?ref=feature"
assert_api_match    "specific file with query"             x   y       api "repos/x/y/contents/.github/PULL_REQUEST_TEMPLATE/bug.md?ref=main"
assert_api_nomatch  "unrelated repos endpoint"                         api repos/o/r/pulls
assert_api_nomatch  "issue template path"                              api repos/o/r/contents/.github/ISSUE_TEMPLATE
assert_api_nomatch  "graphql endpoint"                                 api graphql
assert_api_nomatch  "non-api command"                                  pr list
assert_api_nomatch  "look-alike with suffix"                           api repos/o/r/contents/.github/PULL_REQUEST_TEMPLATE_legacy

echo ""
echo "=== cache freshness ==="
mkdir -p "$PR_TEMPLATE_CACHE_DIR"

if pr_template_check_is_fresh "newowner" "newrepo"; then
    fail "fresh check on missing cache should fail"
else
    pass "missing cache reports not fresh"
fi

record_pr_template_check "owner1" "repo1"
if pr_template_check_is_fresh "owner1" "repo1"; then
    pass "freshly recorded check is fresh"
else
    fail "freshly recorded check should be fresh"
fi

# Per-repo isolation: recording for owner1/repo1 must not satisfy owner2/repo2
if pr_template_check_is_fresh "owner2" "repo2"; then
    fail "cache leaked across repos"
else
    pass "per-repo cache isolation"
fi

# Force stale by backdating mtime beyond TTL
cache_file=$(pr_template_cache_file "owner1" "repo1")
if [ -f "$cache_file" ]; then
    # Set mtime to 2 hours ago
    if [[ "$OSTYPE" == "darwin"* ]]; then
        touch -t "$(date -v-2H +%Y%m%d%H%M.%S)" "$cache_file"
    else
        touch -d "2 hours ago" "$cache_file"
    fi
    if pr_template_check_is_fresh "owner1" "repo1"; then
        fail "stale cache should not be fresh"
    else
        pass "stale cache correctly expired"
    fi
fi

# Custom TTL: 0 means everything is stale
(
    PR_TEMPLATE_CACHE_TTL=0
    record_pr_template_check "ttlowner" "ttlrepo"
    if pr_template_check_is_fresh "ttlowner" "ttlrepo"; then
        fail "TTL=0 should treat freshly written cache as stale"
        exit 1
    else
        pass "TTL=0 honored"
    fi
)

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0

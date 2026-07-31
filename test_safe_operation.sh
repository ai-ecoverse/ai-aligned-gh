#!/bin/bash

# Test is_safe_operation() from executable_gh

# Extract the functions we need
eval "$(sed -n '/^debug_log()/,/^}/p' executable_gh)"
eval "$(sed -n '/^is_readonly_graphql_query()/,/^}/p' executable_gh)"
eval "$(sed -n '/^is_safe_operation()/,/^}/p' executable_gh)"

PASS=0
FAIL=0

assert_safe() {
    local description="$1"
    shift
    if is_safe_operation "$@"; then
        echo "PASS: $description (safe)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description — expected safe (0), got unsafe (1)"
        FAIL=$((FAIL + 1))
    fi
}

assert_unsafe() {
    local description="$1"
    shift
    if is_safe_operation "$@"; then
        echo "FAIL: $description — expected unsafe (1), got safe (0)"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $description (unsafe)"
        PASS=$((PASS + 1))
    fi
}

echo "=== is_safe_operation() tests ==="

# --- Existing safe commands (sanity checks) ---
echo ""
echo "--- Safe commands ---"
assert_safe  "help"                help
assert_safe  "repo view"           repo view
assert_safe  "pr list"             pr list
assert_safe  "issue view"          issue view
assert_safe  "search prs"          search prs
assert_safe  "status"              status
assert_safe  "extension list"      extension list

# --- Existing unsafe commands (sanity checks) ---
echo ""
echo "--- Unsafe commands ---"
assert_unsafe "pr create"          pr create
assert_unsafe "issue create"       issue create
assert_unsafe "repo delete"        repo delete

# --- API method detection (core of PR #47) ---
echo ""
echo "--- API: default GET is safe ---"
assert_safe  "api repos/owner/repo"                          api repos/owner/repo
assert_safe  "api --method GET repos/owner/repo"              api --method GET repos/owner/repo

echo ""
echo "--- API: explicit non-GET methods are unsafe ---"
assert_unsafe "api --method POST repos/owner/repo"            api --method POST repos/owner/repo
assert_unsafe "api --method=POST repos/owner/repo"            api --method=POST repos/owner/repo
assert_unsafe "api --method=post repos/owner/repo"            api --method=post repos/owner/repo
assert_unsafe "api -X POST repos/owner/repo"                  api -X POST repos/owner/repo
assert_unsafe "api -X=POST repos/owner/repo"                  api -X=POST repos/owner/repo
assert_unsafe "api -X PUT repos/owner/repo"                   api -X PUT repos/owner/repo
assert_unsafe "api -X PATCH repos/owner/repo"                 api -X PATCH repos/owner/repo
assert_unsafe "api -X DELETE repos/owner/repo"                api -X DELETE repos/owner/repo

echo ""
echo "--- API: graphql endpoint defaults to POST ---"
assert_unsafe "api graphql"                                   api graphql

echo ""
echo "--- API: body flags imply POST ---"
assert_unsafe "api -f key=val repos/owner/repo"               api -f key=val repos/owner/repo
assert_unsafe "api -F key=val repos/owner/repo"               api -F key=val repos/owner/repo
assert_unsafe "api --field key=val repos/owner/repo"           api --field key=val repos/owner/repo
assert_unsafe "api --raw-field key=val repos/owner/repo"       api --raw-field key=val repos/owner/repo
assert_unsafe "api --input file.json repos/owner/repo"         api --input file.json repos/owner/repo

echo ""
echo "--- API: -X concatenated form ---"
assert_unsafe "api -XPOST repos/owner/repo"                    api -XPOST repos/owner/repo
assert_safe  "api -XGET repos/owner/repo"                      api -XGET repos/owner/repo

echo ""
echo "--- API: /graphql with leading slash ---"
assert_unsafe "api /graphql"                                    api /graphql

echo ""
echo "--- API: explicit GET overrides body flags ---"
assert_safe  "api --method GET -f key=val repos/owner/repo"   api --method GET -f key=val repos/owner/repo

# --- Read-only GraphQL carve-out ---
echo ""
echo "--- API: read-only graphql queries are safe ---"
assert_safe  "graphql named query with variables" \
    api graphql -f 'query=query($owner:String!,$repo:String!){repository(owner:$owner,name:$repo){pullRequest(number:1){body}}}' -f owner=foo -f repo=bar
assert_safe  "graphql anonymous query shorthand" \
    api graphql -f 'query={viewer{login}}'
assert_safe  "graphql fragment-first document" \
    api graphql -f 'query=fragment F on User{login} query{viewer{...F}}'
assert_safe  "graphql query with leading whitespace" \
    api graphql -f 'query=  query{viewer{login}}'
assert_safe  "graphql query via --raw-field" \
    api graphql --raw-field 'query=query{viewer{login}}'
assert_safe  "graphql query via --field= form" \
    api graphql '--field=query=query{viewer{login}}'
assert_safe  "graphql query with -F typed variable" \
    api graphql -f 'query=query($n:Int!){viewer{login}}' -F n=5
assert_safe  "graphql query with --hostname" \
    api graphql -f 'query=query{viewer{login}}' --hostname github.com
assert_safe  "/graphql endpoint with read-only query" \
    api /graphql -f 'query=query{viewer{login}}'

echo ""
echo "--- API: graphql writes and uninspectable documents stay unsafe ---"
assert_unsafe "graphql mutation" \
    api graphql -f 'query=mutation{addStar(input:{starrableId:"x"}){clientMutationId}}'
assert_unsafe "graphql multi-operation document with mutation" \
    api graphql -f 'query=query A{viewer{login}} mutation B{addStar(input:{starrableId:"x"}){clientMutationId}}'
assert_unsafe "graphql uppercase MUTATION" \
    api graphql -f 'query=MUTATION{x}'
assert_unsafe "graphql repeated query= fields, one a mutation" \
    api graphql -f 'query=query{viewer{login}}' -f 'query=mutation{x}'
assert_unsafe "graphql query from file" \
    api graphql -F 'query=@query.graphql'
assert_unsafe "graphql query from stdin" \
    api graphql -F 'query=@-'
assert_unsafe "graphql with --input body" \
    api graphql -f 'query=query{viewer{login}}' --input body.json
assert_unsafe "graphql subscription" \
    api graphql -f 'query=subscription{x}'
assert_unsafe "graphql without query document" \
    api graphql -f owner=foo
assert_unsafe "graphql explicit POST stays gated" \
    api graphql --method POST -f 'query=query{viewer{login}}'
assert_unsafe "REST endpoint with query-shaped field is not graphql" \
    api repos/owner/repo/issues -f 'query=query{viewer{login}}'

# --- gh-stack extension (stacked pull requests) ---
# gh-stack builds its own go-gh client instead of shelling out to `gh`, so its
# writes are never re-evaluated by this wrapper. The writing subcommands must
# take the exchange path so GH_TOKEN is set to the as-a-bot token.
echo ""
echo "--- stack: read-only and local-only subcommands are safe ---"
assert_safe  "stack view"          stack view
assert_safe  "stack init"          stack init
assert_safe  "stack add"           stack add
assert_safe  "stack modify"        stack modify
assert_safe  "stack rebase"        stack rebase
assert_safe  "stack push"          stack push
assert_safe  "stack switch"        stack switch
assert_safe  "stack up"            stack up
assert_safe  "stack down"          stack down
assert_safe  "stack top"           stack top
assert_safe  "stack bottom"        stack bottom
assert_safe  "stack trunk"         stack trunk
assert_safe  "stack alias"         stack alias
assert_safe  "stack feedback"      stack feedback

echo ""
echo "--- stack: mutating subcommands are gated ---"
assert_unsafe "stack submit"       stack submit
assert_unsafe "stack sync"         stack sync
assert_unsafe "stack link"         stack link
assert_unsafe "stack merge"        stack merge
assert_unsafe "stack unstack"      stack unstack
assert_unsafe "stack checkout"     stack checkout
assert_unsafe "stack submit with flags" stack submit --draft
assert_unsafe "stack merge with repo override" stack merge --repo owner/name

echo ""
echo "--- stack: unknown subcommands fail closed ---"
assert_unsafe "stack (no subcommand)"   stack
assert_unsafe "stack future-subcommand" stack some-new-preview-command

echo ""
echo "--- other extensions keep the fast path ---"
assert_safe  "dash extension"      dash
assert_safe  "workflow-peek extension" workflow-peek pr 123

echo ""
echo "--- API: = forms of body flags imply POST ---"
assert_unsafe "api --field=key=val"  api '--field=title=hi' repos/owner/repo
assert_unsafe "api --raw-field=key=val" api '--raw-field=body=hi' repos/owner/repo
assert_unsafe "api --input=file"     api '--input=file.json' repos/owner/repo

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0


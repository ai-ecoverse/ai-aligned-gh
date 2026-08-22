# 🤖 AI-Aligned-GH: The Transparent GitHub CLI Wrapper for AI Attribution

[![79% Vibe_Coded](https://img.shields.io/badge/79%25-Vibe_Coded-ff69b4?style=for-the-badge&logo=claude&logoColor=white)](https://github.com/ai-ecoverse/vibe-coded-badge-action)

![create_a_modern_m_image](https://github.com/user-attachments/assets/969463fc-4276-4ed1-8e20-6fee8aafeb3c)

A transparent wrapper for the GitHub CLI (`gh`) that automatically detects when it's being invoked by an AI tool and ensures all actions are properly attributed to a bot acting on behalf of the user, rather than appearing to come directly from the user.

## 🎯 The Problem

When AI coding assistants (Claude, Cursor, Gemini, etc.) use the GitHub CLI to perform actions like creating PRs, issues, or comments, those actions appear to come directly from you. This creates:

- **Attribution confusion**: Was this action taken by you or your AI assistant?
- **Audit trail issues**: No clear record of AI involvement in repository changes
- **Trust concerns**: Other developers can't distinguish between human and AI actions

## 💡 The Solution

AI-Aligned-GH is a transparent wrapper that:

1. **Intercepts all `gh` calls** without requiring any changes to how AI tools work
2. **Detects AI usage** through process tree analysis and environment variables
3. **Exchanges tokens** via the [as-a-bot](https://github.com/ai-ecoverse/as-a-bot) service
4. **Ensures proper attribution** so AI actions show as "as-a-bot[bot] on behalf of @username"

## 🚀 Quick Install

```bash
# One-line install
curl -fsSL https://raw.githubusercontent.com/ai-ecoverse/ai-aligned-gh/main/install.sh | sh

# Add to PATH (if needed)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Because `~/.local/bin/gh` shadows the real `gh` for everything on the machine, the
installer never writes to it directly. It downloads the wrapper to a staging file in
`~/.local/bin`, checks that the file is complete and executable, and only then swaps it
into place with an atomic `mv`. An interrupted or failed install therefore leaves your
existing `gh` untouched. When an upgrade replaces an existing wrapper, the previous
version is kept as `~/.local/bin/gh.backup.<timestamp>` so you can roll back with:

```bash
cp ~/.local/bin/gh.backup.<timestamp> ~/.local/bin/gh
```

## 🔧 How It Works

### The Wrapper Pattern

Unlike a GitHub CLI extension (which would require AI tools to consciously call `gh ai` instead of `gh`), this is a **transparent wrapper** that intercepts all `gh` calls:

```
AI Tool → gh (wrapper) → Detection → Token Exchange → gh (real) → GitHub API
                ↓                           ↓
           Our wrapper              as-a-bot service
```

### Installation Location

The wrapper installs itself as `gh` in `~/.local/bin`, which must come **before** the real `gh` in your PATH:

```bash
$ which -a gh
/home/user/.local/bin/gh    # Our wrapper (first in PATH)
/usr/bin/gh                  # Real gh CLI
```

### AI Detection

The wrapper detects AI tools through:

1. **Environment variables**: `CLAUDE_CODE`, `CURSOR_AGENT`, `GEMINI_CLI`, etc.
2. **Process tree analysis**: Walks up parent processes looking for AI tool signatures
3. **Process name matching**: Identifies `claude`, `cursor`, `gemini`, etc. in process names

### Token Exchange Flow

When an AI is detected and performing a write operation:

1. Wrapper gets the current repository from `git config`
2. Checks if the as-a-bot GitHub App is installed
3. Exchanges user token for bot token via the as-a-bot service
4. Executes `gh` with the bot token

Read-only operations (like `gh pr list`) skip token exchange for performance.
This includes `gh api graphql` calls whose inline `query=` document is provably
read-only (a `query`/`fragment` document with no `mutation` keyword). GraphQL
documents that contain a mutation, come from a file or stdin (`-F query=@…`,
`--input`), or use an explicit non-GET `--method` stay on the gated path.

### `gh auth token` returns the bot token

When an AI tool runs `gh auth token`, the wrapper returns the **as-a-bot
user-to-server token**, not your personal token. This closes the most common
way agents bypass attribution: capturing the personal token from `gh auth
token` and calling the GitHub API directly (e.g. `curl -H "Authorization: token
<token>"`), which would record actions as you instead of as `as-a-bot[bot]`.
Because the bot token is what comes back, that path now stays attributed.

Humans are unaffected — when no AI tool is detected, `gh auth token` passes
through to the real `gh` and returns your personal token as usual. If the bot
token cannot be issued (app not yet authorized), the command fails closed rather
than falling back to your personal token.

### Stacked pull requests (`gh stack`)

GitHub's [stacked pull requests](https://docs.github.com/en/pull-requests/get-started/about-stacked-prs)
ship as the `github/gh-stack` extension rather than as part of core `gh`. The
wrapper gates the subcommands that write to GitHub — `submit`, `sync`, `link`,
`merge`, `unstack`, `checkout` — so they run with the as-a-bot token. Navigation
and local-only subcommands (`view`, `init`, `add`, `modify`, `rebase`, `push`,
`switch`, `up`, `down`, `top`, `bottom`, `trunk`, `alias`, `feedback`) stay on
the fast path. Subcommands added later are gated by default.

This is needed because `gh-stack` does **not** shell out to `gh pr create`. It
is a Go binary that builds its own [go-gh](https://github.com/cli/go-gh) client
and creates PRs, repoints bases, and merges over GraphQL/REST directly, so those
writes never come back through this wrapper. go-gh picks its token in the order
`GH_TOKEN` → `GITHUB_TOKEN` → `oauth_token` in `hosts.yml` → shelling out to
`gh auth token`; only that last fallback reaches the wrapper. Gating puts the
bot token in `GH_TOKEN`, which wins outright — otherwise stacks created with
`GH_TOKEN` set (CI, containers) or with the token stored in `hosts.yml` (no
system keyring) would land as you rather than as `as-a-bot[bot]`.

Note that branch pushes are a separate path: `git push` authenticates through
the `gh auth git-credential` helper, which `gh auth setup-git` wires up with an
absolute path to the real `gh`, bypassing the wrapper. `gh stack push` and the
push half of `submit`/`sync` are therefore attributed to you regardless of this
gating. Commit authorship is governed by `git config user.name`/`user.email`, not
by the token.

Any other extension that talks to the GitHub API itself rather than shelling out
to `gh` has the same gap. If you add one, audit it and list it alongside `stack`
in `is_safe_operation`.

## 📋 Prerequisites

1. **GitHub CLI**: Install from [cli.github.com](https://cli.github.com/)
2. **GitHub App**: Install [as-a-bot](https://github.com/apps/as-a-bot) on your repositories
3. **Authentication**: Be authenticated with `gh auth login`
4. **jq** (recommended): For JSON parsing during token exchange

## 🎮 Usage

Once installed, the wrapper works **completely transparently**. AI tools continue to call `gh` normally:

```bash
# AI tools just use gh as usual
gh pr create --title "Add new feature" --body "..."
gh issue comment 123 --body "Fixed in latest commit"

# The wrapper automatically handles attribution when AI is detected
```

### Debug Mode

See what's happening under the hood:

```bash
GH_AI_DEBUG=true gh pr list
```

Output:
```
[DEBUG] Starting AI detection from PID 12345
[DEBUG] Detected Claude in process tree
[INFO] AI detected: claude - checking for bot token exchange...
[DEBUG] Found origin URL: https://github.com/user/repo.git
[DEBUG] Parsed owner: user, repo: repo
[INFO] Successfully exchanged token - actions will be attributed to bot
```

### Testing AI Detection

Force AI detection for testing:

```bash
# Simulate different AI environments
OR_APP_NAME=Aider gh issue list
AUGMENT_API_TOKEN=test gh issue list
CLAUDE_CODE=1 gh issue list
CURSOR_AGENT=1 gh pr view 123
GEMINI_CLI=1 gh repo clone user/repo
KIMI_CLI=1 gh pr create --title "Test" --body "Testing Kimi detection"
```

### Working with Third-Party Repos

When the `as-a-bot` app isn't installed on a repository you don't own, you can't install it yourself. Use `gh impersonate` to explicitly opt in to using your personal token for that repo:

```bash
# Skip bot attribution for a specific repo
gh impersonate someorg/somerepo

# Skip for all repos in an org
gh impersonate someorg/*

# See which repos are in the list
gh impersonate --list

# Remove a repo from the list
gh impersonate --remove someorg/somerepo
```

This is an explicit opt-in — the wrapper will still fail loudly for repos not in the list, so you always know when attribution is missing.

## 🖼️ Uploading Images (`gh image`)

`gh` cannot attach images or videos to PRs and issues ([cli/cli#12960](https://github.com/cli/cli/issues/12960)) — a real limitation for coding agents that want to include screenshots or screen recordings. The wrapper adds a `gh image` subcommand that uploads a file to an R2 bucket via the [as-a-bot](https://github.com/ai-ecoverse/as-a-bot) image-upload flow and prints a stable URL you can embed in Markdown:

```bash
$ gh image screenshot.png
https://repo--owner.agentbin.net/<sha256>.png

# Then embed it:
gh pr comment 42 --body "Before/after: ![screenshot](https://repo--owner.agentbin.net/<sha256>.png)"
```

Supported types: `png jpg jpeg gif webp svg avif mp4 mov webm`. Use `--repo owner/repo` outside a repository directory and `--timeout <seconds>` to adjust the wait (default 180s).

With `--markdown` (`-m`) the output is ready-to-embed markup, and with `--html` it is an HTML tag. Images use image markup; videos use labelled links because GitHub rejects externally hosted video through its image proxy and strips external `<video>` elements. The default bare-URL output is unchanged:

```bash
gh pr comment 42 --body "Before/after: $(gh image --markdown after.png)"
# → Before/after: ![after](https://repo--owner.agentbin.net/<sha256>.png)

gh pr comment 42 --body "Before/after: $(gh image --html after.png)"
# → Before/after: <img src="https://repo--owner.agentbin.net/<sha256>.png" alt="after">

# Video output stays clickable instead of producing broken image markup
gh image --markdown demo.mp4
# → [demo.mp4](https://repo--owner.agentbin.net/<sha256>.mp4)

gh image --html demo.mp4
# → <a href="https://repo--owner.agentbin.net/<sha256>.mp4">demo.mp4</a>
```

To make the command discoverable at the moment it matters, the wrapper prints a short stderr tip pointing at `gh image` whenever an AI agent runs `gh pr create` or `gh issue create` — agents otherwise assume image attachment is impossible and skip screenshots entirely.

### How it works

1. `gh image` computes the file's SHA-256 hash and dispatches the repo's `image-upload.yml` workflow with the hash and extension. **GitHub only lets users with write access dispatch workflows** — that's the authorization model: uploading requires the same permission as pushing code. Under an AI tool, the dispatch uses the as-a-bot token like every other write.
2. The workflow is a secret-free relay: it proves the repository's identity to the as-a-bot worker via GitHub Actions OIDC. The worker mints an R2 PUT URL that is **bound to the content hash** (the signature covers `x-amz-checksum-sha256`, so the URL physically cannot upload different content).
3. `gh image` polls the worker, uploads the file to the pre-signed URL, verifies it is serveable, and prints the URL (stdout carries only the URL, so agents can capture it).

Storage is content-addressed (`owner/repo/<sha256>.<ext>`): re-uploading the same file returns the same URL instantly without dispatching anything, and a URL can never change content after publication. Uploads are kept for **90 days** — re-running `gh image` on the same file renews the same URL for another 90 days.

### Repository setup (one-time)

Install the [as-a-bot GitHub App](https://github.com/apps/as-a-bot) on the repository. It commits the `image-upload.yml` workflow automatically — the repository needs **no secrets and no other configuration**.

See the [full design document](https://github.com/ai-ecoverse/as-a-bot/blob/main/docs/image-upload-design.md) for the architecture and trust model.

## 📝 Pull Request Template Safeguard

When an AI tool is detected, the wrapper refuses `gh pr create` (and its `gh pr new` alias) until the agent has explicitly checked whether the target repository defines pull request templates. This nudges agents to discover and use existing PR templates instead of opening PRs with ad-hoc descriptions.

### How the safeguard works

1. The agent runs `gh pr create` for `owner/repo`.
2. The wrapper looks for a recent "PR template check" cache entry for that repo. If none exists, it exits with code 1 and prints instructions.
3. The agent runs `gh api repos/<owner>/<repo>/contents/.github/PULL_REQUEST_TEMPLATE` (or `.../PULL_REQUEST_TEMPLATE.md`, or a specific template path inside that directory).
4. The wrapper observes the call, records a timestamp in `~/.cache/ai-aligned-gh/pr-template-checks/<owner>__<repo>`, and lets the underlying `gh api` request through unchanged.
5. The next `gh pr create` for the same repo succeeds (up to the cache TTL).

### What counts as a valid check

Any `gh api` call whose endpoint matches one of:

```
repos/<owner>/<repo>/contents/.github/PULL_REQUEST_TEMPLATE
repos/<owner>/<repo>/contents/.github/PULL_REQUEST_TEMPLATE/
repos/<owner>/<repo>/contents/.github/PULL_REQUEST_TEMPLATE.md
repos/<owner>/<repo>/contents/.github/PULL_REQUEST_TEMPLATE/<file>.md
```

A leading `/` and a trailing `?ref=...` query string are accepted. A 404 result from GitHub still counts: the agent has done the check, and the wrapper now knows it can let `pr create` through.

### Cache behaviour

- One cache entry per repository at `~/.cache/ai-aligned-gh/pr-template-checks/<owner>__<repo>`.
- Default TTL is one hour (`PR_TEMPLATE_CACHE_TTL=3600`). Override the TTL by exporting `PR_TEMPLATE_CACHE_TTL` (seconds). Override the location by exporting `PR_TEMPLATE_CACHE_DIR`.
- The safeguard is bypassed entirely when no AI tool is detected, so human use of `gh pr create` is unaffected.

### Example flow

```bash
$ CLAUDE_CODE=1 gh pr create --title "Add feature" --body "..."

=================================================================
  PR Template Check Required
=================================================================

  AI tool detected: claude
  Repository: ai-ecoverse/ai-aligned-gh

  Before creating a pull request from an AI agent, you must
  check whether this repository defines pull request templates.
  Run:

    gh api repos/ai-ecoverse/ai-aligned-gh/contents/.github/PULL_REQUEST_TEMPLATE
  ...

$ CLAUDE_CODE=1 gh api repos/ai-ecoverse/ai-aligned-gh/contents/.github/PULL_REQUEST_TEMPLATE
# (response shows templates or 404 — either way the check is recorded)

$ CLAUDE_CODE=1 gh pr create --title "Add feature" --body "..."
# proceeds normally for the next hour
```

## 🤖 Supported AI Tools

The wrapper automatically detects:

| AI Tool | Detection Method | Environment Variable |
|---------|------------------|---------------------|
| [Aider](https://aider.chat/) | Process name + env | `OR_APP_NAME=Aider` |
| Auggie (Augment Code) | Process name + env | `AUGMENT_API_TOKEN` |
| Amp (Sourcegraph) | Process name + env | `AGENT=amp`, `AMP_HOME` |
| Claude (Anthropic) | Process name + env | `CLAUDE_CODE`, `ANTHROPIC_SHELL` |
| Codex CLI (OpenAI) | Process name + env | `CODEX_CLI` |
| [Crush](https://charm.sh/tools/crush/) (Charm) | Process name only | (detected via process tree) |
| Cursor | Process name + env | `CURSOR_AGENT` |
| Droid (Factory AI) | Process name + env | `DROID_CLI` |
| Gemini (Google) | Process name + env | `GEMINI_CLI` |
| [Goose](https://github.com/block/goose) (Block) | Process name + env | `GOOSE_TERMINAL` |
| GitHub Copilot CLI | Process name + env | `GITHUB_COPILOT_CLI_MODE=true` |
| Kimi CLI | Process name + env | `KIMI_CLI` |
| OpenCode | Process name + env | `OPENCODE_AI` |
| Qwen Code (Alibaba) | Process name + env | `QWEN_CODE` |
| Zed AI | Process name + env | `ZED_AI` |

## ⚙️ Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `GH_AI_DEBUG` | Enable debug output | `false` |
| `AS_A_BOT_URL` | as-a-bot service URL | `https://as-bot-worker.minivelos.workers.dev` |
| `GH_TOKEN` | GitHub token override | (uses `gh auth token`) |
| `PR_TEMPLATE_CACHE_TTL` | PR template check cache lifetime (seconds) | `3600` |
| `PR_TEMPLATE_CACHE_DIR` | PR template check cache directory | `~/.cache/ai-aligned-gh/pr-template-checks` |
| `GH_IMAGE_WORKFLOW` | Workflow file `gh image` dispatches | `image-upload.yml` |
| `GH_IMAGE_TIMEOUT` | Default `gh image` wait for the upload URL (seconds) | `180` |
| `AI_ALIGNED_GH_BIN` | Override path to the real `gh` (testing hook; unset in normal use) | (auto-detected) |

### PATH Configuration

The wrapper **must** be found before the real `gh` in your PATH:

```bash
# Check PATH order
echo $PATH | tr ':' '\n'

# Verify wrapper is first
which -a gh
```

## 🔒 Security

- **No token storage**: Tokens are exchanged on-demand, never stored
- **Preserves permissions**: Bot tokens have the same permissions as user tokens
- **Transparent operation**: All actions are logged and auditable
- **Fails safely**: If token exchange fails, falls back to normal operation

## 📝 Example Scenarios

### Scenario 1: AI Creates a Pull Request

Without AI-Aligned-GH:
```
trieloff opened pull request #123
```

With AI-Aligned-GH:
```
as-a-bot[bot] opened pull request #123 on behalf of @trieloff
```

### Scenario 2: AI Comments on an Issue

Without AI-Aligned-GH:
```
@trieloff commented: "This has been fixed in the latest commit"
```

With AI-Aligned-GH:
```
as-a-bot[bot] commented on behalf of @trieloff: "This has been fixed in the latest commit"
```

## 🔍 Verifying AI Attribution

Want to check if a GitHub action was performed by an AI? Use these `gh api` commands to inspect the provenance:

### Check Issue Attribution
```bash
# Check who created an issue and which app (if any) was used
gh api repos/OWNER/REPO/issues/NUMBER --jq '{
  user: .user.login,
  app: .performed_via_github_app.slug // "none"
}'

# Example
gh api repos/ai-ecoverse/ai-aligned-gh/issues/15 --jq '{
  user: .user.login,
  app: .performed_via_github_app.slug
}'
# Output: {"user": "trieloff", "app": "as-a-bot"}
```

### Check Issue Comment Attribution
```bash
# Check the latest comment on an issue
gh api repos/OWNER/REPO/issues/NUMBER/comments --jq '.[-1] | {
  user: .user.login,
  app: .performed_via_github_app.slug // "none"
}'
```

### Check Pull Request Attribution
```bash
# Check who created a PR
gh api repos/OWNER/REPO/pulls/NUMBER --jq '{
  user: .user.login,
  app: .performed_via_github_app.slug // "none"
}'

# Note: PRs created with installation tokens show user as "app-name[bot]"
# PRs created with user-to-server tokens show the actual username
```

### Check PR Comment Attribution
```bash
# Check the latest comment on a PR (same endpoint as issues)
gh api repos/OWNER/REPO/issues/NUMBER/comments --jq '.[-1] | {
  user: .user.login,
  app: .performed_via_github_app.slug // "none"
}'
```

### Understanding the Results

- **User-to-server token** (correct): `user: "your-username"`, `app: "as-a-bot"`
  - Actions are attributed to you but marked as performed via the app
  - This is what ai-aligned-gh creates

- **Installation token** (incorrect): `user: "as-a-bot[bot]"`, `app: "none"`
  - Actions appear to come from the bot itself
  - Loses human attribution

- **Direct user action**: `user: "your-username"`, `app: "none"`
  - Regular human action without any AI involvement

### ⚠️ Important API Limitation

The `performed_via_github_app` field is **inconsistently available** across GitHub API endpoints (undocumented):

| Action | Has `performed_via_github_app`? |
|--------|----------------------------------|
| Issue creation | ✅ Yes |
| Issue comments | ✅ Yes |
| PR comments | ✅ Yes |
| **Pull request creation** | ❌ **No** |
| PR reviews | ❌ No |

This is a GitHub API limitation, not an issue with our implementation. Even with proper user-to-server tokens, PRs themselves don't include app attribution in the API response.

### Quick Check Script

Check all recent activity in a repo:
```bash
# List recent issues with attribution
for issue in $(gh issue list --limit 5 --json number --jq '.[].number'); do
  echo -n "Issue #$issue: "
  gh api repos/OWNER/REPO/issues/$issue --jq '{
    user: .user.login,
    app: .performed_via_github_app.slug // "none"
  }'
done
```

## 🚧 Troubleshooting

### Wrapper Not Being Called

```bash
# Check if wrapper is installed
ls -la ~/.local/bin/gh

# Check PATH order
which -a gh

# Ensure ~/.local/bin is first in PATH
export PATH="$HOME/.local/bin:$PATH"
```

### App Not Installed (Your Repo)

If you see "GitHub App Installation Required" for a repo you own:

1. Visit https://github.com/apps/as-a-bot
2. Click "Install" or "Configure"
3. Select the repository where you want AI attribution
4. Save the configuration

### App Not Installed (Third-Party Repo)

If you see "Third-Party Repository — App Not Installed" for a repo you don't control:

```bash
# Opt in to using your personal token for this repo
gh impersonate owner/repo

# Or for an entire org
gh impersonate owner/*
```

This skips bot attribution for that repo. See `gh impersonate --list` to review.

### Token Exchange Fails

```bash
# Check authentication
gh auth status

# Test token exchange manually
GH_AI_DEBUG=true CLAUDE_CODE=1 gh pr list
```

### AI Not Detected

```bash
# Check process tree
ps -ef | grep -E "claude|cursor|gemini"

# Force detection with environment variable
CLAUDE_CODE=1 gh issue list
```

## 🤝 Contributing

To add support for a new AI tool:

1. Add detection logic to the `detect_ai_tool` function in `executable_gh`
2. Add environment variable check (e.g., `NEW_AI_TOOL`)
3. Add process name pattern matching
4. Test with `GH_AI_DEBUG=true`
5. Submit a pull request

## 📜 License

Apache 2.0 - See LICENSE file for details

## 🔗 Related Projects

Part of the **[AI Ecoverse](https://github.com/ai-ecoverse/.github)** - a comprehensive ecosystem of tools for AI-assisted development:

- [yolo](https://github.com/ai-ecoverse/yolo) - AI CLI launcher with worktree isolation
- [am-i-ai](https://github.com/ai-ecoverse/am-i-ai) - Shared AI detection library (powers this tool)
- [ai-aligned-git](https://github.com/ai-ecoverse/ai-aligned-git) - Git wrapper for safe AI commit practices
- [vibe-coded-badge-action](https://github.com/ai-ecoverse/vibe-coded-badge-action) - Badge showing AI-generated code percentage
- [gh-workflow-peek](https://github.com/ai-ecoverse/gh-workflow-peek) - Smarter GitHub Actions log filtering
- [upskill](https://github.com/ai-ecoverse/gh-upskill) - Install Claude/Agent skills from other repositories
- [as-a-bot](https://github.com/ai-ecoverse/as-a-bot) - GitHub App token broker for proper AI attribution

## 🙏 Acknowledgments

This project is inspired by and follows the design philosophy of [ai-aligned-git](https://github.com/ai-ecoverse/ai-aligned-git) by @trieloff. The transparent wrapper pattern ensures AI tools don't need to be modified or trained to use special commands - they just work.

---

*"The best interface is no interface. The wrapper is transparent, the AI doesn't know it exists, and yet every action is properly attributed."*

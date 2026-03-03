# 🤖 AI-Aligned-GH: The Transparent GitHub CLI Wrapper for AI Attribution

[![51% Vibe_Coded](https://img.shields.io/badge/51%25-Vibe_Coded-ff69b4?style=for-the-badge&logo=claude&logoColor=white)](https://github.com/ai-ecoverse/vibe-coded-badge-action)

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

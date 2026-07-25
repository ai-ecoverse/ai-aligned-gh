#!/bin/bash

# Test AI detection functions from executable_gh

# Set debug mode
export DEBUG=true

# Extract just the functions we need from executable_gh. The detection
# functions live in the bundled am-i-ai section (ami_* plus the
# backward-compatibility aliases), so pull in that whole block.
eval "$(sed -n '/^debug_log()/,/^}/p' executable_gh)"
eval "$(sed -n '/^# --- BEGIN BUNDLED am-i-ai ---$/,/^# --- END BUNDLED am-i-ai ---$/p' executable_gh)"

echo "=== AI Detection Test for ai-aligned-gh ==="
echo "Current PID: $$"

echo -e "\n=== Environment Variables ==="
echo "CLAUDECODE: '$CLAUDECODE'"
echo "CLAUDE_CODE_ENTRYPOINT: '$CLAUDE_CODE_ENTRYPOINT'"
echo "TERM_PROGRAM: '$TERM_PROGRAM'"
echo "ZED_TERM: '$ZED_TERM'"
echo "GEMINI_CLI: '$GEMINI_CLI'"
echo "QWEN_CODE: '$QWEN_CODE'"
echo "CURSOR_AGENT: '$CURSOR_AGENT'"
echo "OPENCODE_AI: '$OPENCODE_AI'"
echo "CODEX_CLI: '$CODEX_CLI'"
echo "OR_APP_NAME: '$OR_APP_NAME'"
echo "GOOSE_TERMINAL: '$GOOSE_TERMINAL'"
if [ -n "$AUGMENT_API_TOKEN" ]; then
    echo "AUGMENT_API_TOKEN: [SET]"
else
    echo "AUGMENT_API_TOKEN: ''"
fi
echo "Note: Crush has no environment variables, detected via process tree only"

echo -e "\n=== Environment Detection ==="
env_result=$(check_env_vars)
echo "Environment detected: '$env_result'"

echo -e "\n=== Process Tree Detection ==="
ps_result=$(check_ps_tree)
echo "Process tree detected: '$ps_result'"

echo -e "\n=== Final Detection ==="
final=$(detect_ai_tool)
echo "Final result: '$final'"

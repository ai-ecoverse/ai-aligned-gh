#!/bin/bash

# AI-Aligned-GH Installer Script
# Installs the gh wrapper to ~/.local/bin
# Supports both local installation and curl | sh
#
# Usage with curl:
#   curl -fsSL https://raw.githubusercontent.com/ai-ecoverse/ai-aligned-gh/main/install.sh | sh
#   UPGRADE=true curl -fsSL https://raw.githubusercontent.com/ai-ecoverse/ai-aligned-gh/main/install.sh | sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
WHITE='\033[0;37m'
NC='\033[0m' # No Color

# Installation directory
INSTALL_DIR="$HOME/.local/bin"
SCRIPT_NAME="gh"
SOURCE_SCRIPT="executable_gh"
RAW_BASE_URL="https://raw.githubusercontent.com/ai-ecoverse/ai-aligned-gh/main"

# Verbose mode flag
VERBOSE=${VERBOSE:-false}
# Upgrade mode flag
UPGRADE=${UPGRADE:-false}

# Function to print colored output
print_color() {
    local color=$1
    shift
    printf "${color}%s${NC}\n" "$*"
}

# Function to print verbose output
print_verbose() {
    if [ "$VERBOSE" = true ]; then
        print_color "$BLUE" "[VERBOSE] $*"
    fi
}

# Function to check if a command exists
command_exists() {
    local cmd="$1"
    print_verbose "Checking if command '$cmd' exists..."
    if command -v "$cmd" >/dev/null 2>&1; then
        print_verbose "Command '$cmd' found at: $(command -v "$cmd")"
        return 0
    else
        print_verbose "Command '$cmd' not found"
        return 1
    fi
}

# Function to check if directory is in PATH
is_in_path() {
    local dir=$1
    print_verbose "Checking if '$dir' is in PATH..."
    print_verbose "Current PATH: $PATH"
    if [[ ":$PATH:" == *":$dir:"* ]]; then
        print_verbose "Directory '$dir' is in PATH"
        return 0
    else
        print_verbose "Directory '$dir' is NOT in PATH"
        return 1
    fi
}

# Function to detect the user's shell
detect_shell() {
    print_verbose "Detecting shell..."
    if [ -n "$SHELL" ]; then
        local shell_name
        shell_name=$(basename "$SHELL")
        print_verbose "Detected shell: $shell_name (from SHELL=$SHELL)"
        echo "$shell_name"
    else
        print_verbose "SHELL variable not set, defaulting to bash"
        echo "bash"  # Default to bash
    fi
}

# Function to get shell config file
get_shell_config() {
    local shell_name
    shell_name=$(detect_shell)
    case "$shell_name" in
        bash)
            if [ -f "$HOME/.bashrc" ]; then
                echo "$HOME/.bashrc"
            else
                echo "$HOME/.bash_profile"
            fi
            ;;
        zsh)
            echo "$HOME/.zshrc"
            ;;
        fish)
            echo "$HOME/.config/fish/config.fish"
            ;;
        *)
            echo "$HOME/.profile"
            ;;
    esac
}

# Function to check prerequisites
check_prerequisites() {
    print_color "$BLUE" "Checking prerequisites..."
    
    # Check if gh is installed
    if ! command_exists gh; then
        print_color "$RED" "Error: GitHub CLI (gh) is not installed"
        print_color "$YELLOW" "Please install gh first:"
        print_color "$WHITE" "  https://cli.github.com/"
        exit 1
    fi
    print_color "$GREEN" "✓ GitHub CLI (gh) is installed"
    
    # Check if jq is installed (needed for token parsing)
    if ! command_exists jq; then
        print_color "$YELLOW" "Warning: jq is not installed"
        print_color "$YELLOW" "Installing jq is recommended for proper token exchange"
        print_color "$WHITE" "  macOS: brew install jq"
        print_color "$WHITE" "  Linux: apt-get install jq or yum install jq"
    else
        print_color "$GREEN" "✓ jq is installed"
    fi
    
    # Check if git is installed (needed for repo detection)
    if ! command_exists git; then
        print_color "$YELLOW" "Warning: git is not installed"
        print_color "$YELLOW" "Repository detection will not work without git"
    else
        print_color "$GREEN" "✓ git is installed"
    fi
}

# Main installation
print_color "$BLUE" "=== AI-Aligned-GH Installer ==="
echo

# Check prerequisites
check_prerequisites
echo

# Create installation directory
print_color "$BLUE" "Creating installation directory..."
mkdir -p "$INSTALL_DIR"
print_color "$GREEN" "✓ Directory created: $INSTALL_DIR"
echo

# Check if wrapper already exists
if [ -f "$INSTALL_DIR/$SCRIPT_NAME" ] && [ "$UPGRADE" != "true" ]; then
    # Check if it's our wrapper or the real gh
    if grep -q "ai-aligned-gh" "$INSTALL_DIR/$SCRIPT_NAME" 2>/dev/null || \
       grep -q "as-a-bot" "$INSTALL_DIR/$SCRIPT_NAME" 2>/dev/null; then
        print_color "$YELLOW" "AI-Aligned-GH wrapper already installed at $INSTALL_DIR/$SCRIPT_NAME"
        print_color "$YELLOW" "To upgrade, run with UPGRADE=true:"
        print_color "$WHITE" "  UPGRADE=true $0"
        exit 0
    else
        print_color "$RED" "Warning: $INSTALL_DIR/$SCRIPT_NAME exists but doesn't appear to be the AI-Aligned wrapper"
        print_color "$YELLOW" "This might be the real gh binary or another wrapper"
        print_color "$YELLOW" "Please backup or remove it before installing"
        exit 1
    fi
fi

# Download or copy the wrapper script
print_color "$BLUE" "Installing wrapper script..."
if [ -f "$SOURCE_SCRIPT" ]; then
    # Local installation
    print_verbose "Copying from local file: $SOURCE_SCRIPT"
    cp "$SOURCE_SCRIPT" "$INSTALL_DIR/$SCRIPT_NAME"
    chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
    print_color "$GREEN" "✓ Wrapper script installed from local file"
else
    # Remote installation
    print_verbose "Downloading from: $RAW_BASE_URL/$SOURCE_SCRIPT"
    if command_exists curl; then
        curl -fsSL "$RAW_BASE_URL/$SOURCE_SCRIPT" -o "$INSTALL_DIR/$SCRIPT_NAME"
    elif command_exists wget; then
        wget -q "$RAW_BASE_URL/$SOURCE_SCRIPT" -O "$INSTALL_DIR/$SCRIPT_NAME"
    else
        print_color "$RED" "Error: Neither curl nor wget is available"
        exit 1
    fi
    chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
    print_color "$GREEN" "✓ Wrapper script downloaded and installed"
fi
echo

# Check if directory is in PATH
if is_in_path "$INSTALL_DIR"; then
    print_color "$GREEN" "✓ $INSTALL_DIR is already in your PATH"
    
    # Check if it's before the real gh
    real_gh=$(which gh 2>/dev/null || echo "")
    if [ -n "$real_gh" ]; then
        wrapper_gh="$INSTALL_DIR/$SCRIPT_NAME"
        if [ "$real_gh" = "$wrapper_gh" ]; then
            print_color "$GREEN" "✓ Wrapper is correctly positioned in PATH"
        else
            print_color "$YELLOW" "Warning: The real gh at $real_gh might be found before the wrapper"
            print_color "$YELLOW" "Make sure $INSTALL_DIR comes first in your PATH"
        fi
    fi
else
    print_color "$YELLOW" "⚠ $INSTALL_DIR is not in your PATH"
    echo
    print_color "$YELLOW" "To add it to your PATH, run:"
    
    config_file=$(get_shell_config)
    shell_name=$(detect_shell)
    
    case "$shell_name" in
        fish)
            print_color "$WHITE" "  echo 'set -gx PATH $INSTALL_DIR \$PATH' >> $config_file"
            print_color "$WHITE" "  source $config_file"
            ;;
        *)
            print_color "$WHITE" "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> $config_file"
            print_color "$WHITE" "  source $config_file"
            ;;
    esac
fi

echo
print_color "$GREEN" "=== Installation Complete! ==="
echo
print_color "$BLUE" "The AI-Aligned-GH wrapper has been installed."
echo
print_color "$YELLOW" "What it does:"
print_color "$WHITE" "  • Detects when gh is called by AI tools (Claude, Cursor, etc.)"
print_color "$WHITE" "  • Exchanges tokens via as-a-bot service for proper attribution"
print_color "$WHITE" "  • Ensures AI actions are attributed to bots, not you"
echo
print_color "$YELLOW" "Next steps:"
print_color "$WHITE" "  1. Ensure $INSTALL_DIR is in your PATH (see above if needed)"
print_color "$WHITE" "  2. Install the as-a-bot GitHub App on your repositories:"
print_color "$BLUE" "     https://github.com/apps/as-a-bot"
print_color "$WHITE" "  3. Test with: GH_AI_DEBUG=true gh auth status"
echo
print_color "$GREEN" "Enjoy safer AI-assisted development!"
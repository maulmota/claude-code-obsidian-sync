#!/bin/bash
# install.sh: Install claude-sync for macOS/Linux
# Can be run from a clone or piped from curl:
#   curl -fsSL https://raw.githubusercontent.com/maulmota/claude-code-obsidian-sync/main/install.sh | bash

set -euo pipefail

REPO="maulmota/claude-code-obsidian-sync"
INSTALL_DIR="$HOME/.local/bin"
SCRIPT_NAME="claude-sync"

echo "claude-code-obsidian-sync installer"
echo ""

# Get the script — either from local clone or download
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/$SCRIPT_NAME" ]; then
  SOURCE="$SCRIPT_DIR/$SCRIPT_NAME"
  echo "Installing from local clone..."
else
  echo "Downloading claude-sync from GitHub..."
  SOURCE=$(mktemp)
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/$SCRIPT_NAME" -o "$SOURCE"
  trap 'rm -f "$SOURCE"' EXIT
fi

# Check for jq
if ! command -v jq &>/dev/null; then
  echo ""
  echo "Warning: jq is not installed. claude-sync needs jq for JSON operations."
  echo "  macOS:  brew install jq"
  echo "  Ubuntu: sudo apt install jq"
  echo ""
fi

# Install
mkdir -p "$INSTALL_DIR"
cp "$SOURCE" "$INSTALL_DIR/$SCRIPT_NAME"
chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
echo "Installed $SCRIPT_NAME to $INSTALL_DIR/$SCRIPT_NAME"

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  echo ""
  echo "$INSTALL_DIR is not on your PATH."

  # Detect shell rc file
  SHELL_RC=""
  case "$(basename "$SHELL")" in
    zsh)  SHELL_RC="$HOME/.zshrc" ;;
    bash) SHELL_RC="$HOME/.bashrc" ;;
    *)    SHELL_RC="$HOME/.profile" ;;
  esac

  read -r -p "Add it to $SHELL_RC? [Y/n]: " add_path
  add_path="${add_path:-Y}"
  if [[ "$add_path" =~ ^[Yy] ]]; then
    echo "" >> "$SHELL_RC"
    echo "# claude-sync" >> "$SHELL_RC"
    echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$SHELL_RC"
    echo "Added to $SHELL_RC. Run 'source $SHELL_RC' or open a new terminal."
  else
    echo "Add this to your shell config manually:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
fi

# Offer to run init
echo ""
read -r -p "Run 'claude-sync init' now? [Y/n]: " run_init
run_init="${run_init:-Y}"
if [[ "$run_init" =~ ^[Yy] ]]; then
  echo ""
  "$INSTALL_DIR/$SCRIPT_NAME" init
fi

echo ""
echo "Done! claude-sync is ready to use."

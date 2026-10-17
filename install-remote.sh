#!/usr/bin/env bash
set -euo pipefail

trap 'echo "Error on line $LINENO. Exiting." >&2' ERR

REPO_URL="https://raw.githubusercontent.com/mdfaridmiah/claude-ce/main/claude-ce.sh"
INSTALL_DIR="$HOME/.local/bin"
INSTALL_PATH="$INSTALL_DIR/claude-ce"

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: 'curl' is required but not installed." >&2
    exit 2
fi

mkdir -p "$INSTALL_DIR"

tmp_file="$(mktemp "${INSTALL_DIR}/.claude-ce.download.XXXXXX")"
cleanup() {
    [[ -f "$tmp_file" ]] && rm -f "$tmp_file"
}
trap cleanup EXIT

if ! curl -fsSL "$REPO_URL" -o "$tmp_file"; then
    echo "Error: failed to download from $REPO_URL" >&2
    exit 2
fi

if [[ ! -s "$tmp_file" ]]; then
    echo "Error: downloaded file is empty." >&2
    exit 2
fi

first_line="$(head -n 1 "$tmp_file")"
if [[ "$first_line" != "#!/usr/bin/env bash" && "$first_line" != "#!/bin/bash" ]]; then
    echo "Error: downloaded file does not look like a bash script (first line: $first_line)" >&2
    exit 2
fi

chmod +x "$tmp_file"
mv "$tmp_file" "$INSTALL_PATH"
trap - EXIT

case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
        cat <<EOF
Warning: $INSTALL_DIR is not in your PATH.
Add it by appending the following line to your shell rc file (~/.bashrc or ~/.zshrc):

  export PATH="\$HOME/.local/bin:\$PATH"

Then reload your shell: source ~/.zshrc  (or source ~/.bashrc)
EOF
        ;;
esac

if [[ $# -gt 0 ]]; then
    exec "$INSTALL_PATH" "$@"
fi

cat <<EOF
✓ Installed to $INSTALL_PATH

Usage:
  claude-ce add work
  claude-ce add personal
  claude-ce list
EOF

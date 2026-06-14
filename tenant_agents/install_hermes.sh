#!/usr/bin/env bash
set -euo pipefail

#############################################################################
# Hermes Agent Installation Script
# Docs: https://hermes-agent.nousresearch.com/docs/getting-started/installation
# Description: Thin wrapper around the official Nous Research installer.
# Usage: ./install_hermes.sh [UPSTREAM_OPTIONS]
#   --help          Show this help message
#
# Common upstream options:
#   --skip-browser  Skip Playwright/Chromium install
#   --branch NAME   Install from a specific branch
#   --dir PATH      Install into a specific directory
#############################################################################

UPSTREAM_URL="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"

show_help() {
    sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//'
    cat <<EOF

All other arguments are passed to the official installer:
  curl -fsSL ${UPSTREAM_URL} | bash -s -- [UPSTREAM_OPTIONS]
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Required command not found: curl" >&2
    exit 1
fi

echo "Running official Hermes Agent installer..."
curl -fsSL "$UPSTREAM_URL" | bash -s -- "$@"

echo ""
echo "Hermes installer finished."
echo "Reload your shell if needed: source ~/.bashrc  # or source ~/.zshrc"
echo "Start Hermes with: hermes"

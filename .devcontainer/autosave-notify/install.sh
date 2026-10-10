#!/usr/bin/env bash
# Installs the "Autosave Notify" VS Code extension (pop-up notifications for autosave.sh).
#
# The extension is a .vsix file published as a GitHub Release asset, so its source code
# does not have to be in your repository. This script downloads it and installs it with
# the `code` CLI of the VS Code server.
#
# Usage: bash .devcontainer/autosave-notify/install.sh [--force]
#   --force   reinstall even if the extension is already installed (also updates it)
#
# Env vars:
#   AUTOSAVE_NOTIFY_VSIX_URL  where to download the .vsix from
#                             (default: the latest release of the template repository)
#
# This never fails the Codespace: on any problem it prints a hint and exits 0.

DEFAULT_URL="https://github.com/taka1156/codespaces-autosnapshot/releases/latest/download/autosave-notify.vsix"
URL="${AUTOSAVE_NOTIFY_VSIX_URL:-$DEFAULT_URL}"
ID="local.autosave-notify"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

say() { echo "[autosave-notify] $*"; }

# the `code` CLI is not always on PATH outside an integrated terminal
CODE="$(command -v code || true)"
if [ -z "$CODE" ]; then
  for candidate in /vscode/vscode-server/bin/*/*/bin/remote-cli/code; do
    if [ -x "$candidate" ]; then CODE="$candidate"; break; fi
  done
fi
if [ -z "$CODE" ]; then
  say "the 'code' command was not found. Run this script again from a VS Code terminal."
  exit 0
fi

if [ "$FORCE" = 0 ] && "$CODE" --list-extensions 2>/dev/null | grep -qix "$ID"; then
  say "already installed ($ID). Use --force to reinstall or update."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
VSIX="$WORK/autosave-notify.vsix"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL --retry 2 --max-time 60 -o "$VSIX" "$URL" 2>/dev/null
elif command -v wget >/dev/null 2>&1; then
  wget -q -T 60 -O "$VSIX" "$URL" 2>/dev/null
else
  say "neither 'curl' nor 'wget' is available, so the extension was not installed."
  exit 0
fi

# a .vsix is a zip file ("PK"); this also rejects an HTML error page
if [ ! -s "$VSIX" ] || [ "$(head -c 2 "$VSIX")" != "PK" ]; then
  say "could not download the extension from $URL"
  say "Backups still work. Check the URL (the repository must be public) or set AUTOSAVE_NOTIFY_VSIX_URL."
  exit 0
fi

if "$CODE" --install-extension "$VSIX" >/dev/null 2>&1; then
  say "installed $ID. If no pop-up appears, run 'Developer: Reload Window'."
else
  say "installation failed. Run this script again from a VS Code terminal."
fi
exit 0

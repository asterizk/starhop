#!/bin/bash
# uninstall_starhop.command — StarHop Uninstaller
# Removes LaunchAgent and the installed app data in:
#   ~/Library/Application Support/com.krishengreenwell.StarHop
# Shows a concise modal summary of real actions taken.
set -euo pipefail

summary=()

say_msg() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Resolve context (works from .app/Contents/Resources or anywhere)
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$THIS_DIR"

APP_BUNDLE="$(cd "$THIS_DIR/../.." && pwd)"

# Resolve app icon
ICON_NAME="$(/usr/bin/defaults read "$APP_BUNDLE/Contents/Info" CFBundleIconFile 2>/dev/null || echo AppIcon)"
[[ "$ICON_NAME" != *.icns ]] && ICON_NAME="${ICON_NAME}.icns"
ICON_PATH="$APP_BUNDLE/Contents/Resources/$ICON_NAME"
[[ -f "$ICON_PATH" ]] || ICON_PATH="$APP_BUNDLE"   # fallback to bundle as icon

# Paths
LA_PLIST_ID="com.krishengreenwell.starhop"
LA_DIR="${HOME}/Library/LaunchAgents"
LA_PLIST_PATH="${LA_DIR}/${LA_PLIST_ID}.plist"
APP_SUPPORT="${HOME}/Library/Application Support/com.krishengreenwell.StarHop"

# ---------- LaunchAgent (stop + remove if present) ----------
LA_PLIST_ID="com.krishengreenwell.starhop"
LA_DIR="${HOME}/Library/LaunchAgents"
LA_PLIST_PATH="${LA_DIR}/${LA_PLIST_ID}.plist"
USER_ID="$(id -u)"

# Best-effort stop by label or by plist path (quiet if not loaded)
launchctl bootout "gui/${USER_ID}" "${LA_PLIST_ID}" >/dev/null 2>&1 || \
launchctl bootout "gui/${USER_ID}" "${LA_PLIST_PATH}" >/dev/null 2>&1 || true

# Optional: make sure it won't auto-start (harmless if absent)
launchctl disable "gui/${USER_ID}/${LA_PLIST_ID}" >/dev/null 2>&1 || true

# Remove the agent plist if it still exists
if [ -f "${LA_PLIST_PATH}" ]; then
  rm -f "${LA_PLIST_PATH}"
  summary+=("LaunchAgent plist removed")
fi

# 3) Remove installed application support (includes .venv and copied sources)
if [ -d "${APP_SUPPORT}" ]; then
  say "Removing ${APP_SUPPORT}"
  rm -rf "${APP_SUPPORT}" || true
  summary+=("Application Support folder removed")
fi

# Build summary
if [ ${#summary[@]} -eq 0 ]; then
  SUMMARY_TEXT="StarHop was already fully uninstalled."
else
  SUMMARY_TEXT="StarHop has been uninstalled.\n\n"
  for line in "${summary[@]}"; do
    SUMMARY_TEXT+="• ${line}\n"
  done
fi

# Show modal (fallback to console if no GUI)
if command -v osascript >/dev/null 2>&1 && [ -z "${SSH_TTY:-}" ]; then
  /usr/bin/osascript <<APPLESCRIPT
set iconPath to "${ICON_PATH}"
set iconAlias to (POSIX file iconPath) as alias
display dialog "$(printf '%s' "${SUMMARY_TEXT}")" buttons {"OK"} default button 1 with icon iconAlias
APPLESCRIPT
else
  echo -e "\n${SUMMARY_TEXT}"
fi

exit 0

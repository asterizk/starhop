#!/bin/bash
# APOD Grabber Uninstaller (idempotent, always removes .venv, minimal popup)
# - Only reports real actions taken (skips "already gone" chatter)
set -euo pipefail

summary=()

# ---------- Resolve repo root ----------
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "$THIS_DIR" == *".app/Contents/Resources"* ]]; then
  REPO_DIR="$(cd "$THIS_DIR/../../.." && pwd)"
elif [[ "$THIS_DIR" == */scripts/internal ]]; then
  REPO_DIR="$(cd "$THIS_DIR/../.." && pwd)"
else
  REPO_DIR="$THIS_DIR"
fi
cd "$REPO_DIR"

# ---------- LaunchAgent (unload + remove if present) ----------
LA_PLIST_ID="com.krishengreenwell.apod"
LA_DIR="${HOME}/Library/LaunchAgents"
LA_PLIST_PATH="${LA_DIR}/${LA_PLIST_ID}.plist"

if launchctl list | grep -q "${LA_PLIST_ID}"; then
  launchctl unload -w "${LA_PLIST_PATH}" || true
  summary+=("LaunchAgent unloaded")
fi

if [ -f "${LA_PLIST_PATH}" ]; then
  rm -f "${LA_PLIST_PATH}"
  summary+=("LaunchAgent plist removed")
fi

# ---------- ALWAYS remove .venv (no prompts) ----------
if [ -d ".venv" ]; then
  rm -rf ".venv" || true
  summary+=(".venv removed")
fi

# ---------- Build summary text ----------
if [ ${#summary[@]} -eq 0 ]; then
  SUMMARY_TEXT="APOD Grabber was already fully uninstalled."
else
  SUMMARY_TEXT="APOD Grabber uninstaller finished.\n\n"
  for line in "${summary[@]}"; do
    SUMMARY_TEXT+="• ${line}\n"
  done
fi

# ---------- Show popup (fallback to console) ----------
if command -v osascript >/dev/null 2>&1 && [ -z "${SSH_TTY:-}" ]; then
  /usr/bin/osascript <<APPLESCRIPT
display dialog "$(printf '%s' "${SUMMARY_TEXT}")" buttons {"OK"} default button 1 with icon note
APPLESCRIPT
else
  echo -e "\n${SUMMARY_TEXT}"
fi

exit 0

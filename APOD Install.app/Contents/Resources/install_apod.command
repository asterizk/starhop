#!/bin/bash
# install_apod.command — APOD Grabber Installer (ALWAYS shows modal dialog after first run)
set -euo pipefail

say_msg() { echo "[$(date '+%H:%M:%S')] $*"; }

# Resolve repo root
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "$THIS_DIR" == *".app/Contents/Resources"* ]]; then
  REPO_DIR="$(cd "$THIS_DIR/../../.." && pwd)"
elif [[ "$THIS_DIR" == */scripts/internal ]]; then
  REPO_DIR="$(cd "$THIS_DIR/../.." && pwd)"
else
  REPO_DIR="$THIS_DIR"
fi
cd "$REPO_DIR"
say_msg "Working directory: $REPO_DIR"

# Python 3
say_msg "Checking for Python 3..."
if ! command -v python3 >/dev/null 2>&1; then
  say_msg "Python 3 not found; opening python.org…"
  open "https://www.python.org/downloads/mac-osx/"
  /usr/bin/osascript -e 'display dialog "Please install Python 3 from python.org, then run again." buttons {"OK"} default button 1 with icon note'
  exit 1
fi
PYTHON_SYS="$(command -v python3)"
say_msg "Using system Python: $PYTHON_SYS"

# LaunchControl / fdautil
LC_APP="/Applications/LaunchControl.app"
if [ ! -d "$LC_APP" ]; then
  say_msg "LaunchControl not found; opening vendor site…"
  open "https://www.soma-zone.com/LaunchControl/"
  /usr/bin/osascript -e 'display dialog "LaunchControl is required (for fdautil permissions helper).\n\nInstall it, then run again." buttons {"OK"} default button 1 with icon note'
  exit 1
fi
FDAUTIL=""
if [ -x "/Applications/LaunchControl.app/Contents/Helpers/fdautil" ]; then
  FDAUTIL="/Applications/LaunchControl.app/Contents/Helpers/fdautil"
elif [ -x "/usr/local/bin/fdautil" ]; then
  FDAUTIL="/usr/local/bin/fdautil"
else
  CANDIDATE="$(mdfind 'kMDItemFSName == \"fdautil\"c' | grep -i \"LaunchControl\" | head -n 1 || true)"
  if [ -n "$CANDIDATE" ] && [ -x "$CANDIDATE" ]; then
    FDAUTIL="$CANDIDATE"
  fi
fi
say_msg "Using fdautil at: ${FDAUTIL:-<not found>}"

# venv
if [ ! -d ".venv" ]; then
  say_msg "Creating virtual environment (.venv)…"
  "$PYTHON_SYS" -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
PYTHON_BIN="$(pwd)/.venv/bin/python"

# requirements
REQ="${REPO_DIR}/requirements.txt"
if [ ! -f "${REQ}" ]; then
  say_msg "ERROR: requirements.txt not found at ${REQ}"
  exit 1
fi
say_msg "Upgrading pip and installing dependencies…"
python -m pip install --upgrade pip
python -m pip install -r "${REQ}"

# LaunchAgent
LA_DIR="${HOME}/Library/LaunchAgents"
LA_PLIST="com.krishengreenwell.apod.plist"
SRC_PLIST="${REPO_DIR}/dependencies/${LA_PLIST}"
DST_PLIST="${LA_DIR}/${LA_PLIST}"

mkdir -p "${LA_DIR}"
cp "${SRC_PLIST}" "${DST_PLIST}"
/usr/bin/sed -i '' -E "s|(>)(/.*python[^<]*)(<)|\\1${PYTHON_BIN}\\3|" "${DST_PLIST}"
/usr/bin/sed -i '' -E "s|(>)(/.*apod-grabber)(<)|\\1${REPO_DIR}\\3|" "${DST_PLIST}"
if [ -n "${FDAUTIL:-}" ]; then
  /usr/bin/sed -i '' -E "s|(>)(/[^<]*/fdautil)(<)|\\1${FDAUTIL}\\3|" "${DST_PLIST}" || true
fi

say_msg "Reloading LaunchAgent…"
if launchctl list | grep -q "com.krishengreenwell.apod" ; then
  launchctl unload -w "${DST_PLIST}" || true
fi
launchctl load -w "${DST_PLIST}"

# Run once
say_msg "Running APOD Grabber once…"
set +e
python apodgrab.py
APP_RC=$?
set -e
say_msg "APOD run finished with status: ${APP_RC}"

# Always show modal dialog
open -g -a "LaunchControl" || true
GUIDE_TITLE="APOD Grabber installed"
GUIDE_BODY="If prompted, grant:
• Files & Folders / Full Disk Access to the Python in .venv
• Automation: Python → Finder
You can adjust these later in System Settings → Privacy & Security."
/usr/bin/osascript <<APPLESCRIPT
display dialog "${GUIDE_TITLE}.\n\n${GUIDE_BODY}" buttons {"OK"} default button 1 with icon note
APPLESCRIPT

exit $APP_RC

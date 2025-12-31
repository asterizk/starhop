#!/bin/bash
# install_starhop.command — StarHop Installer
# Based on your latest install_starhop.command, but no repo is required at runtime.
# Payload (starhop.py, requirements.txt, plist) must be embedded under
#   <App>.app/Contents/Resources/payload/
# The app installs to: ~/Library/Application Support/com.krishengreenwell.StarHop
# and loads the LaunchAgent from there. Always shows a modal dialog after first run.
set -euo pipefail

say_msg() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

start_progress() {
  ICON_PATH="$ICON_PATH" LOG_FILE="$LOG_FILE" /usr/bin/osascript <<'OSA' &
use scripting additions
set iconAlias to (POSIX file (system attribute "ICON_PATH")) as alias
set logPath to (system attribute "LOG_FILE")

-- Looping dialog that stays up until the parent script kills this osascript process
repeat
  try
    display dialog "StarHop is installing…\n\nThis can take a few minutes while Python and dependencies are set up." ¬
      buttons {"View Log"} default button "View Log" giving up after 86400 with icon iconAlias
    -- If user clicked "View Log", open Console to the live log, then loop to keep the window up
    do shell script "open -a Console " & quoted form of logPath
  on error
    exit repeat
  end try
end repeat
OSA
  PROGRESS_PID=$!
}

stop_progress() {
  [ -n "${PROGRESS_PID:-}" ] && kill "$PROGRESS_PID" 2>/dev/null || true
  unset PROGRESS_PID
}


# Run natively even if launched under Rosetta, but keep errors visible to the GUI wrapper
if [ "${STARHOP_FORCE_ARM64:-0}" != 1 ] && [ "$(uname -m)" != "arm64" ]; then
  say_msg "Detected Rosetta (x86_64); re-running installer as arm64..."
  export STARHOP_FORCE_ARM64=1
  # If exec fails, print a clear error and exit with a distinct code
  exec /usr/bin/arch -arm64 /bin/bash "$0" "$@" || {
    say_msg "ERROR: Failed to re-exec as arm64 (status $?)."
    exit 97
  }
fi

# Assert we are really native now (helps debug weird environments)
if [ "$(uname -m)" != "arm64" ]; then
  say_msg "ERROR: Still not arm64 after re-exec; aborting."
  exit 98
fi

# --- Locate Resources/payload ---
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "$THIS_DIR" == *".app/Contents/Resources"* ]]; then
  RES_DIR="$THIS_DIR"
else
  # dev fallback: allow running from scripts/internal by treating parent as Resources
  RES_DIR="$(cd "$THIS_DIR/.." && pwd)"
fi
PAYLOAD_DIR="${RES_DIR}/payload"

APP_BUNDLE="$(cd "$THIS_DIR/../.." && pwd)"
LOG_FILE="$HOME/Library/Logs/com.krishengreenwell.StarHop/install.log"

# Validate payload contents
SRC_STARHOP="${PAYLOAD_DIR}/starhop.py"
REQ="${PAYLOAD_DIR}/requirements.txt"
LA_PLIST_NAME="com.krishengreenwell.starhop.plist"
SRC_PLIST="${PAYLOAD_DIR}/${LA_PLIST_NAME}"

if [ ! -f "${SRC_STARHOP}" ] || [ ! -f "${REQ}" ] || [ ! -f "${SRC_PLIST}" ]; then
  say_msg "ERROR: Installer payload not found in ${PAYLOAD_DIR}"
  /usr/bin/osascript -e 'display dialog "Installer payload missing.\nRebuild or re-download StarHop Install.app." buttons {"OK"} default button 1 with icon stop'
  exit 1
fi

# --- Install destination (stable path for LaunchAgent) ---
APP_SUPPORT="${HOME}/Library/Application Support/com.krishengreenwell.StarHop"
mkdir -p "${APP_SUPPORT}"
say_msg "Install path: ${APP_SUPPORT}"

LOG_DIR="$HOME/Library/Logs/com.krishengreenwell.StarHop"
mkdir -p "$LOG_DIR"

# Copy sources to install path
cp -f "${SRC_STARHOP}" "${APP_SUPPORT}/starhop.py"
cp -f "${REQ}" "${APP_SUPPORT}/requirements.txt"

# --- NASA API key (required) ---
KEY_FILE="${APP_SUPPORT}/nasa_apod_key"

# Resolve app icon
ICON_NAME="$(/usr/bin/defaults read "$APP_BUNDLE/Contents/Info" CFBundleIconFile 2>/dev/null || echo AppIcon)"
[[ "$ICON_NAME" != *.icns ]] && ICON_NAME="${ICON_NAME}.icns"
ICON_PATH="$APP_BUNDLE/Contents/Resources/$ICON_NAME"
[[ -f "$ICON_PATH" ]] || ICON_PATH="$APP_BUNDLE"   # fallback to bundle as icon

if [ ! -f "$KEY_FILE" ]; then
  say_msg "Prompting user for NASA API key..."

  NASA_KEY=$(ICON_PATH="$ICON_PATH" NASA_URL="https://api.nasa.gov/index.html" /usr/bin/osascript <<'APPLESCRIPT'
set iconPath to system attribute "ICON_PATH"
set theURL   to system attribute "NASA_URL"
set iconAlias to (POSIX file iconPath) as alias

repeat
  set dlg to display dialog ¬
    "StarHop needs a NASA API Key to operate." & return & return & ¬
    "Click “Open Site” to create one, then paste it here." ¬
    default answer "" buttons {"Cancel", "Open Site", "Continue"} ¬
    default button "Continue" with icon iconAlias
  set btn to button returned of dlg
  if btn is "Open Site" then
    try
      do shell script "open " & quoted form of theURL
    end try
  else if btn is "Cancel" then
    error number -128
  else
    set theKey to text returned of dlg
    if theKey is not "" and theKey is not "DEMO_KEY" then return theKey
    display dialog "Please paste your real NASA API key (not DEMO_KEY)." ¬
      buttons {"OK"} default button 1 with icon iconAlias
  end if
end repeat
APPLESCRIPT
  ) || true

  NASA_KEY="$(printf '%s' "${NASA_KEY:-}" | tr -d '\r\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  if [ -z "${NASA_KEY}" ]; then
    say_msg "No NASA API key provided; aborting install."
    /usr/bin/osascript -e 'display dialog "Installation aborted: a NASA API key is required." buttons {"OK"} default button 1 with icon stop'
    exit 2
  fi

  umask 077
  printf '%s\n' "$NASA_KEY" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"

  say_msg "Validating NASA API key..."
  if ! curl -fsS "https://api.nasa.gov/planetary/apod?api_key=$(cat "$KEY_FILE")&date=2020-01-01&thumbs=true" >/dev/null; then
    say_msg "Key validation failed."
    /usr/bin/osascript -e 'display dialog "That NASA API key didn’t validate.\n\nOpen the NASA site, create a key, then run the installer again." buttons {"OK"} default button 1 with icon stop'
    rm "$KEY_FILE"
    exit 2
  fi
  say_msg "NASA API key validated."
fi

# --- Python 3 ---
say_msg "Checking for Python 3..."
if ! command -v python3 >/dev/null 2>&1; then
  say_msg "Python 3 not found; opening python.org..."
  open "https://www.python.org/downloads/mac-osx/"
  /usr/bin/osascript -e 'display dialog "Please install Python 3 from python.org, then run again." buttons {"OK"} default button 1 with icon note'
  exit 1
fi
PYTHON_SYS="$(command -v python3)"
say_msg "Using system Python: $PYTHON_SYS"

# --- LaunchControl / fdautil ---
LC_APP="/Applications/LaunchControl.app"
if [ ! -d "$LC_APP" ]; then
  say_msg "LaunchControl not found; opening vendor site..."
  open "https://www.soma-zone.com/LaunchControl/"
  /usr/bin/osascript -e 'display dialog "LaunchControl is required (for fdautil permissions helper).\n\nInstall it, then run again." buttons {"OK"} default button 1 with icon note'
  exit 1
fi
FDAUTIL=""
if [ -x "/Applications/LaunchControl.app/Contents/MacOS/fdautil" ]; then
  # LaunchControl >= 2.10
  FDAUTIL="/Applications/LaunchControl.app/Contents/MacOS/fdautil"
elif [ -x "/Applications/LaunchControl.app/Contents/Helpers/fdautil" ]; then
  # LaunchControl < 2.10
  FDAUTIL="/Applications/LaunchControl.app/Contents/Helpers/fdautil"
elif [ -x "/usr/local/bin/fdautil" ]; then
  # LaunchControl optionally allows install here
  FDAUTIL="/usr/local/bin/fdautil"
else
  CANDIDATE="$(
    { mdfind 'kMDItemFSName == "fdautil"c' 2>/dev/null | grep -i 'LaunchControl\.app/Contents' | head -n1; } || true
  )"
  if [ -n "$CANDIDATE" ] && [ -x "$CANDIDATE" ]; then
    FDAUTIL="$CANDIDATE"
  fi
fi
say_msg "Using fdautil at: ${FDAUTIL:-<not found>}"

# Show progress window for the long-running install phase
start_progress

# Ensure we close the window no matter what
trap 'stop_progress' EXIT INT TERM

# --- venv (lives in Application Support) ---
cd "${APP_SUPPORT}"
if [ ! -d ".venv" ]; then
  say_msg "Creating virtual environment (.venv)..."
  "$PYTHON_SYS" -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
PYTHON_BIN="${APP_SUPPORT}/.venv/bin/python"

# --- requirements (from copied file in APP_SUPPORT) ---
REQ_INST="${APP_SUPPORT}/requirements.txt"
if [ ! -f "${REQ_INST}" ]; then
  say_msg "ERROR: requirements.txt not found at ${REQ_INST}"
  exit 1
fi
say_msg "Upgrading pip and installing dependencies..."
"${PYTHON_BIN}" -m pip install --upgrade pip
"${PYTHON_BIN}" -m pip install -r "${REQ_INST}"

# --- LaunchAgent ---
LA_DIR="${HOME}/Library/LaunchAgents"
DST_PLIST="${LA_DIR}/${LA_PLIST_NAME}"

mkdir -p "${LA_DIR}"
cp -f "${SRC_PLIST}" "${DST_PLIST}"

/usr/libexec/PlistBuddy -c 'Delete :ProgramArguments' "$DST_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$DST_PLIST"

if [ -n "${FDAUTIL:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string ${FDAUTIL}" "$DST_PLIST"
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string exec' "$DST_PLIST"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string ${PYTHON_BIN}" "$DST_PLIST"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string ${APP_SUPPORT}/starhop.py" "$DST_PLIST"
else
  # no fdautil --> run directly
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:0 string /usr/bin/arch' "$DST_PLIST"
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string -arm64' "$DST_PLIST"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string ${PYTHON_BIN}" "$DST_PLIST"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string ${APP_SUPPORT}/starhop.py" "$DST_PLIST"
fi

# WorkingDirectory
/usr/libexec/PlistBuddy -c "Set :WorkingDirectory ${APP_SUPPORT}" "$DST_PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :WorkingDirectory string ${APP_SUPPORT}" "$DST_PLIST"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath $LOG_DIR/agent.out.log" "$DST_PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string $LOG_DIR/agent.out.log" "$DST_PLIST"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath $LOG_DIR/agent.err.log" "$DST_PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $LOG_DIR/agent.err.log" "$DST_PLIST"

say_msg "Reloading LaunchAgent..."
USER_ID="$(id -u)"
LA_PLIST_ID="com.krishengreenwell.starhop"

# Best-effort stop by label or by plist path (quiet if not loaded)
launchctl bootout "gui/${USER_ID}" "${LA_PLIST_ID}" >/dev/null 2>&1 || \
launchctl bootout "gui/${USER_ID}" "${DST_PLIST}" >/dev/null 2>&1 || true

# Bootstrap (load) the service - use modern API for macOS 13+
if launchctl bootstrap "gui/${USER_ID}" "${DST_PLIST}" 2>/dev/null; then
  say_msg "LaunchAgent bootstrapped successfully"
else
  # Fallback to legacy load if bootstrap fails (older macOS)
  launchctl load -w "${DST_PLIST}" 2>/dev/null || true
fi

# --- Run once from install location ---
say_msg "Running StarHop once..."
set +e
"${PYTHON_BIN}" "${APP_SUPPORT}/starhop.py"
APP_RC=$?
set -e
say_msg "StarHop run finished with status: ${APP_RC}"

stop_progress
trap - EXIT INT TERM   # clear trap if you want

ICON_PATH="$ICON_PATH" /usr/bin/osascript <<'OSA'
set p to system attribute "ICON_PATH"
set iconAlias to (POSIX file p) as alias
set dlg to display dialog "StarHop installed.\n\nOpen LaunchControl now to grant fdautil permissions (Automation → System Events/Finder)?" ¬
  buttons {"Not Now","Open LaunchControl"} default button "Open LaunchControl" with icon iconAlias
if button returned of dlg is "Open LaunchControl" then
  do shell script "open -a LaunchControl"
end if
OSA

exit $APP_RC

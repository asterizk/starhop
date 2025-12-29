#!/usr/bin/env bash
# Build .app bundles that EMBED the .command scripts with versioned Info.plist,
# and (for the installer) also embed a runtime payload so the app does not need
# a checked-out repo at runtime.
#
# Outputs apps at the repo root:
#   - StarHop Install.app     → embeds scripts/internal/install_starhop.command
#                            and Resources/payload/{starhop.py,requirements.txt,com.krishengreenwell.starhop.plist}
#   - StarHop Uninstall.app   → embeds scripts/internal/uninstall_starhop.command
#
# Runner: executes embedded script in the FOREGROUND (Dock icon stays visible)
# and redirects ALL output to a single log:
#   ~/Library/Logs/com.krishengreenwell.StarHop/install.log
#
# Usage:
#   VERSION=1.2.3 BUNDLE_PREFIX=com.krishengreenwell.starhop ./tools/packaging/build_apps.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

VERSION="${VERSION:-1.0.0}"
BUNDLE_PREFIX="${BUNDLE_PREFIX:-com.krishengreenwell.starhop}"

SRC_DIR="${REPO_ROOT}/scripts/internal"
RES_DIR="${REPO_ROOT}/resources"
DEP_DIR="${REPO_ROOT}/dependencies"

need () { [ -e "$1" ] || { echo "ERROR: missing $1" >&2; exit 1; }; }

# Required inputs
need "${SRC_DIR}/install_starhop.command"
need "${SRC_DIR}/uninstall_starhop.command"
need "${REPO_ROOT}/starhop.py"
need "${REPO_ROOT}/requirements.txt"
need "${DEP_DIR}/com.krishengreenwell.starhop.plist"
if [ -e "${RES_DIR}/AppIcon.icns" ]; then HAS_ICON=1; else HAS_ICON=0; fi

make_app () {
  local APP_NAME="$1" BUNDLE_ID="$2" EXEC_NAME="$3" EMBED_SCRIPT="$4"
  local APP="${REPO_ROOT}/${APP_NAME}.app"
  local APP_RES="${APP}/Contents/Resources"

  echo "==> Building: ${APP_NAME}.app (v${VERSION}) at repo root"
  rm -rf "${APP}"
  mkdir -p "${APP}/Contents/MacOS" "${APP_RES}"

  # Embed script
  cp "${SRC_DIR}/${EMBED_SCRIPT}" "${APP_RES}/${EMBED_SCRIPT}"
  chmod +x "${APP_RES}/${EMBED_SCRIPT}"

  # Icon (optional)
  if [ $HAS_ICON -eq 1 ]; then
    cp "${RES_DIR}/AppIcon.icns" "${APP_RES}/"
  fi

  # If this is the installer, embed a self-contained payload
  if [[ "${APP_NAME}" == "StarHop Install" ]]; then
    mkdir -p "${APP_RES}/payload"
    cp "${REPO_ROOT}/starhop.py"                      "${APP_RES}/payload/"
    cp "${REPO_ROOT}/requirements.txt"                 "${APP_RES}/payload/"
    cp "${DEP_DIR}/com.krishengreenwell.starhop.plist"    "${APP_RES}/payload/"
  fi

  # Runner: run embedded script in foreground, log to a single file (install.log)
  cat > "${APP}/Contents/MacOS/${EXEC_NAME}" <<'SH'
#!/bin/bash
set -euo pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="${THIS_DIR}/../.."
APP_PARENT="$(cd "${APP_ROOT}/.." && pwd)"
SCRIPT_NAME="@EMBED_SCRIPT@"
SCRIPT_PATH="${APP_ROOT}/Contents/Resources/${SCRIPT_NAME}"

LOG_DIR="${HOME}/Library/Logs/com.krishengreenwell.StarHop"
LOG_FILE="${LOG_DIR}/install.log"   # single consolidated log for install & uninstall
mkdir -p "${LOG_DIR}"

if [ ! -f "${SCRIPT_PATH}" ]; then
  /usr/bin/osascript -e 'display dialog "Embedded script not found:\n\n'"${SCRIPT_NAME}"'\n\nReinstall or re-download this app." buttons {"OK"} default button 1 with icon stop'
  exit 1
fi

# Simple log rotation at ~1MB
if [ -f "${LOG_FILE}" ] && [ "$(wc -c < "${LOG_FILE}")" ] && [ "$(wc -c < "${LOG_FILE}")" -gt 1048576 ]; then
  mv "${LOG_FILE}" "${LOG_FILE%.*}.$(date +%Y%m%d-%H%M%S).log"
fi

# One-shot redirection for the whole runner
umask 022
touch "${LOG_FILE}"
exec >> "${LOG_FILE}" 2>&1
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== ${SCRIPT_NAME} START ====="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] cwd=${APP_PARENT}"

# Run in foreground so Dock icon stays visible
cd "${APP_PARENT}"
set +e
/bin/bash "${SCRIPT_PATH}"
EXIT_CODE=$?
set -e

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ===== ${SCRIPT_NAME} END (exit=${EXIT_CODE}) ====="

ICON_CAND="$APP_ROOT/Contents/Resources/AppIcon.icns"
[ -f "$ICON_CAND" ] || ICON_CAND="$APP_ROOT"  # fallback to bundle

if [ "$EXIT_CODE" -ne 0 ] && [ "$EXIT_CODE" -ne 2 ]; then
  # Not using macOS notifications here because they require enabling from Script Editor which is a step too far
  # (too annoying) to ask of the user.
  # See https://forum.latenightsw.com/t/trying-to-use-terminal-for-display-notification/5068

  ICON_PATH="$ICON_CAND" /usr/bin/osascript <<'OSA'
set p to system attribute "ICON_PATH"
set iconAlias to (POSIX file p) as alias
display dialog "StarHop install/uninstall failed.\nSee install.log for details." ¬
  buttons {"OK","View Log"} default button "View Log" with icon iconAlias
if button returned of result is "View Log" then
  do shell script "open -a Console ~/Library/Logs/com.krishengreenwell.StarHop/install.log"
end if
OSA
fi

exit $EXIT_CODE
SH
  /usr/bin/sed -i '' -e "s|@EMBED_SCRIPT@|${EMBED_SCRIPT}|g" "${APP}/Contents/MacOS/${EXEC_NAME}"
  chmod +x "${APP}/Contents/MacOS/${EXEC_NAME}"

  # Info.plist
  cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key>                <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>         <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>          <string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key>             <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key>  <string>${VERSION}</string>
  <key>CFBundleExecutable</key>          <string>${EXEC_NAME}</string>
  <key>CFBundlePackageType</key>         <string>APPL</string>
  <key>LSMinimumSystemVersion</key>      <string>13.0</string>
  <key>NSHighResolutionCapable</key>     <true/>
  $( [ $HAS_ICON -eq 1 ] && echo "<key>CFBundleIconFile</key><string>AppIcon</string>" )
</dict></plist>
PLIST

  echo "✅ Built ${APP_NAME}.app"
}

make_app "StarHop Install"   "${BUNDLE_PREFIX}.install"   "starhop-install"   "install_starhop.command"
make_app "StarHop Uninstall" "${BUNDLE_PREFIX}.uninstall" "starhop-uninstall" "uninstall_starhop.command"

echo "All apps built (version ${VERSION})."

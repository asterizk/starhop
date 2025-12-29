#!/usr/bin/env bash
# Build .app bundles that EMBED the .command scripts with versioned Info.plist.
# Intended to live in: tools/packaging/
# Outputs apps at the repo root:
#   - APOD Install.app     → embeds scripts/internal/install_apod.command
#   - APOD Uninstall.app   → embeds scripts/internal/uninstall_apod.command
#
# Usage:
#   VERSION=1.2.3 BUNDLE_PREFIX=com.krishengreenwell.apod ./tools/packaging/build_apps_embed_v.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

VERSION="${VERSION:-1.0.0}"
BUNDLE_PREFIX="${BUNDLE_PREFIX:-com.krishengreenwell.apod}"

SRC_DIR="${REPO_ROOT}/scripts/internal"

need () { [ -f "$1" ] || { echo "ERROR: missing $1" >&2; exit 1; }; }
need "${SRC_DIR}/install_apod.command"
need "${SRC_DIR}/uninstall_apod.command"

make_app () {
  local APP_NAME="$1" BUNDLE_ID="$2" EXEC_NAME="$3" EMBED_SCRIPT="$4"
  local APP="${REPO_ROOT}/${APP_NAME}.app"

  echo "==> Building: ${APP_NAME}.app (v${VERSION}) at repo root"
  rm -rf "${APP}"
  mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

  # Embed script
  cp "${SRC_DIR}/${EMBED_SCRIPT}" "${APP}/Contents/Resources/${EMBED_SCRIPT}"
  chmod +x "${APP}/Contents/Resources/${EMBED_SCRIPT}"

  # Runner: cd to app's parent folder, then run embedded script in Terminal
  cat > "${APP}/Contents/MacOS/${EXEC_NAME}" <<'SH'
#!/bin/bash
set -euo pipefail
THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="${THIS_DIR}/../.."
APP_PARENT="$(cd "${APP_ROOT}/.." && pwd)"
SCRIPT_NAME="@EMBED_SCRIPT@"
SCRIPT_PATH="${APP_ROOT}/Contents/Resources/${SCRIPT_NAME}"

if [ ! -f "${SCRIPT_PATH}" ]; then
  osascript -e 'display dialog "Embedded script not found:\n\n'"${SCRIPT_NAME}"'\n\nReinstall or re-download this app." buttons {"OK"} default button 1 with icon stop'
  exit 1
fi

osascript <<OSA
tell application "Terminal"
  activate
  do script "cd " & quoted form of POSIX path of "${APP_PARENT}" & "; " & quoted form of POSIX path of "${SCRIPT_PATH}"
end tell
OSA
SH
  /usr/bin/sed -i '' -e "s|@EMBED_SCRIPT@|${EMBED_SCRIPT}|g" "${APP}/Contents/MacOS/${EXEC_NAME}"
  chmod +x "${APP}/Contents/MacOS/${EXEC_NAME}"

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
  <key>LSMinimumSystemVersion</key>      <string>13.0</string>
</dict></plist>
PLIST

  echo "✅ Built ${APP_NAME}.app"
}

make_app "APOD Install"   "${BUNDLE_PREFIX}.install"   "apod-install"   "install_apod.command"
make_app "APOD Uninstall" "${BUNDLE_PREFIX}.uninstall" "apod-uninstall" "uninstall_apod.command"

echo "All apps built (version ${VERSION})."

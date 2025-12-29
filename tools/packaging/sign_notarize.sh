#!/usr/bin/env bash
# Sign, notarize, and staple versioned apps at repo root:
#   APOD Install.app, APOD Uninstall.app
# Intended to live in: tools/packaging/
#
# Usage:
#   ./tools/packaging/sign_notarize_v.sh "Developer ID Application: Your Name (TEAMID)" AC_PROFILE
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

DEV_ID="${1:-${DEV_ID:-}}"
PROFILE="${2:-${AC_PROFILE:-}}"

if [ -z "${DEV_ID}" ] || [ -z "${PROFILE}" ]; then
  echo "Usage: $0 \"Developer ID Application: Your Name (TEAMID)\" AC_PROFILE" >&2
  exit 1
fi

version_for () {
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist"
}

sign_one () {
  local APP="$1"
  echo "==> Codesigning: ${APP}"
  codesign --force --deep --options runtime --timestamp \
    --sign "${DEV_ID}" "${APP}"
  echo "==> Verifying signature"
  codesign --verify --deep --strict --verbose=2 "${APP}"
}

notarize_one () {
  local APP="$1"
  local VER="$(version_for "${APP}")"
  local ZIP="$(basename "${APP%.app}")-${VER}.zip"
  echo "==> Zipping: ${APP} -> ${ZIP}"
  rm -f "${ZIP}"
  ditto -c -k --keepParent "${APP}" "${ZIP}"

  echo "==> Notarizing: ${ZIP} (profile: ${PROFILE})"
  xcrun notarytool submit "${ZIP}" --keychain-profile "${PROFILE}" --wait

  echo "==> Stapling ticket into ${APP}"
  xcrun stapler staple "${APP}"

  echo "==> Gatekeeper assessment"
  spctl --assess --type execute -vv "${APP}" || true
}

for APP in "APOD Install.app" "APOD Uninstall.app"; do
  if [ ! -d "${APP}" ]; then
    echo "ERROR: ${APP} not found at repo root. Build them first with build_apps_embed_v.sh." >&2
    exit 1
  fi
  sign_one "${APP}"
  notarize_one "${APP}"
done

echo "All done."

#!/usr/bin/env bash
# Sign, notarize, and staple versioned apps at repo root:
#   StarHop Install.app, StarHop Uninstall.app
# Intended to live in: tools/packaging/
#
# Usage:
#   ./tools/packaging/sign_notarize.sh "Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE
#
# The value of NOTARY_PROFILE comes from the following:
#
# xcrun notarytool store-credentials "<name of keychain item to create --> this becomes NOTARY_PROFILE>" \
#  --apple-id "<your Apple ID>" \
#  --team-id "<your team id; determine by running 'security find-identity -p codesigning -v' and noting value inside parentheses>" \
#  --password "<must be an App-Specific Password you generate at appleid.apple.com, not your main Apple ID password>"
#
# Note, for the above to work, your Apple "Developer ID Application" certificate must have previously
# been created inside Xcode in conjunction with a valid Apple Developer account (Xcode --> Settings -->
# Apple Accounts --> Select account --> Manage Certificates --> Add --> Developer ID Application). Note
# that activating an Apple Developer account can sometimes take up to 24h, during which time you will not
# see the 'Add --> Developer ID Application' option.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

DEV_ID="${1:-${DEV_ID:-}}"
PROFILE="${2:-${NOTARY_PROFILE:-}}"

if [ -z "${DEV_ID}" ] || [ -z "${PROFILE}" ]; then
  echo "Usage: $0 \"Developer ID Application: Your Name (TEAMID)\" NOTARY_PROFILE" >&2
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

for APP in "StarHop Install.app" "StarHop Uninstall.app"; do
  if [ ! -d "${APP}" ]; then
    echo "ERROR: ${APP} not found at repo root. Build them first with build_apps.sh." >&2
    exit 1
  fi
  sign_one "${APP}"
  notarize_one "${APP}"
done

echo "All done."

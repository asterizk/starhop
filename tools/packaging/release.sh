#!/usr/bin/env bash
# release.sh — Build, sign, notarize, staple, and package StarHop apps for release.
#
# Defaults: builds a notarized DMG (with both apps) + checksum.
#           ZIPs are optional (via --zip).
#
# Usage:
#   VERSION=1.2.3 BUNDLE_PREFIX=com.krishengreenwell.starhop \
#   ./tools/packaging/release.sh "Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE [--zip] [--gh]
#
# Flags:
#   --zip  Also collect versioned ZIPs produced by sign_notarize.sh
#   --gh   If GitHub CLI (gh) is available, create a GitHub Release and upload artifacts.
#
# Env overrides:
#   VERSION, BUNDLE_PREFIX, DEV_ID, NOTARY_PROFILE (or AC_PROFILE), DO_ZIP=1, DO_DMG=0 to override defaults
#
# Note: NOTARY_PROFILE is the same as ASC_PROFILE in sign_notarize.sh

set -euo pipefail

say(){ echo "[$(date '+%H:%M:%S')] $*"; }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

VERSION="${VERSION:-1.0.0}"
BUNDLE_PREFIX="${BUNDLE_PREFIX:-com.krishengreenwell.starhop}"

DEV_ID="${1:-${DEV_ID:-}}"
PROFILE="${2:-${NOTARY_PROFILE:-${AC_PROFILE:-}}}"

# Defaults: DMG on, ZIP off
DO_DMG="${DO_DMG:-1}"
DO_ZIP="${DO_ZIP:-0}"
DO_GH=0

# Parse optional flags
shift 2 || true
for a in "${@:-}"; do
  case "$a" in
    --zip) DO_ZIP=1 ;;
    --no-dmg) DO_DMG=0 ;;  # escape hatch if needed
    --gh) DO_GH=1 ;;
  esac
done

if [[ -z "${DEV_ID}" || -z "${PROFILE}" ]]; then
  echo "Usage: $0 \"Developer ID Application: Your Name (TEAMID)\" NOTARY_PROFILE [--zip] [--gh]" >&2
  echo "You can also set DEV_ID and NOTARY_PROFILE (or AC_PROFILE) via env vars." >&2
  exit 1
fi

APPS=("StarHop Install.app" "StarHop Uninstall.app")

need () { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing tool '$1'"; exit 1; }; }
need xcrun
need codesign
need shasum

DIST_DIR="dist/${VERSION}"
mkdir -p "${DIST_DIR}"

say "Step 1/4: Build apps (version ${VERSION})"
VERSION="${VERSION}" BUNDLE_PREFIX="${BUNDLE_PREFIX}" ./tools/packaging/build_apps.sh

say "Step 2/4: Sign, notarize, staple apps"
./tools/packaging/sign_notarize.sh "${DEV_ID}" "${PROFILE}"

# sign_notarize.sh creates versioned ZIPs at repo root. Collect if requested, else clean them up.
if [ "${DO_ZIP}" -eq 1 ]; then
  say "Collecting ZIPs into ${DIST_DIR} and generating checksums"
  for APP in "${APPS[@]}"; do
    BASE="$(basename "${APP}" .app)"
    ZIP="${BASE}-${VERSION}.zip"
    if [ -f "${ZIP}" ]; then
      mv -f "${ZIP}" "${DIST_DIR}/"
      ( cd "${DIST_DIR}" && shasum -a 256 "${ZIP}" > "${ZIP}.sha256" )
    fi
  done
else
  # remove any stray zips produced in repo root to keep tree clean
  for APP in "${APPS[@]}"; do
    BASE="$(basename "${APP}" .app)"
    ZIP="${BASE}-${VERSION}.zip"
    [ -f "${ZIP}" ] && rm -f "${ZIP}"
  done
fi

DMG_PATH="${DIST_DIR}/StarHop-${VERSION}.dmg"
if [ "${DO_DMG}" -eq 1 ]; then
  need hdiutil
  say "Step 3/4: Build DMG with both apps"
  STAGING="${DIST_DIR}/staging"
  rm -rf "${STAGING}"
  mkdir -p "${STAGING}"
  cp -R "${APPS[@]}" "${STAGING}/"
  hdiutil create -volname "StarHop" -srcfolder "${STAGING}" -fs HFS+ -format UDZO -ov "${DMG_PATH}"
  rm -rf "${STAGING}"

  say "Notarize + staple DMG"
  xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${PROFILE}" --wait
  xcrun stapler staple "${DMG_PATH}"

  say "Checksum for DMG"
  ( cd "${DIST_DIR}" && shasum -a 256 "$(basename "${DMG_PATH}")" > "$(basename "${DMG_PATH}").sha256" )
else
  say "Skipping DMG (DO_DMG=0)"
fi

say "Step 4/4: (optional) GitHub Release"
if [ ${DO_GH} -eq 1 ]; then
  if command -v gh >/dev/null 2>&1; then
    say "Creating GitHub Release v${VERSION}"
    ARGS=()
    # Include DMG (+ checksum) if present
    if [ -f "${DMG_PATH}" ]; then
      ARGS+=("${DMG_PATH}")
      [ -f "${DMG_PATH}.sha256" ] && ARGS+=("${DMG_PATH}.sha256")
    fi
    # Include ZIPs (+ checksums) if we built them
    if [ "${DO_ZIP}" -eq 1 ]; then
      for f in "${DIST_DIR}"/*.zip "${DIST_DIR}"/*.zip.sha256; do
        [ -f "$f" ] && ARGS+=("$f")
      done
    fi
    gh release create "v${VERSION}" "${ARGS[@]}" \
      --title "StarHop ${VERSION}" \
      --notes "Signed, notarized release.\nIncludes StarHop Install.app and StarHop Uninstall.app.\nDMG by default; ZIPs included only when requested."
  else
    say "GitHub CLI not found; skipping release creation. (Install with 'brew install gh')"
  fi
fi

say "Done. Artifacts in: ${DIST_DIR}"
ls -lh "${DIST_DIR}"

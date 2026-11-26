#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Dirscope.app"
# Prefer /tmp so Desktop/iCloud repos don't hang on xattr or taint the seal with FinderInfo.
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/Dirscope-DerivedData}"
BUILD_DIR="${DERIVED_DATA_PATH}/Build/Products/Release"
SOURCE_APP="${BUILD_DIR}/${APP_NAME}"
DIST_DIR="${ROOT}/dist"
STAGE_DIR="${STAGE_DIR:-/tmp/Dirscope-release-stage}"
VERSION="${DIRSCOPE_VERSION:-1.0.0}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SKIP_NOTARIZE=false
HAS_DEVELOPER_ID=false

usage() {
  cat <<EOF
Usage: $0 [--skip-notarize] [--version VERSION]

Build a Release Dirscope.app, optionally notarize it, and write artifacts to dist/.

Environment:
  DEVELOPMENT_TEAM   Apple Developer Team ID (auto-detected from Developer ID Application if unset)
  NOTARY_PROFILE     Keychain notarytool profile name (required for notarization)
  DIRSCOPE_VERSION   Marketing version tag (default: 1.0.0)

Notes:
  Apple Development certificates alone are not used for distribution or notarization.
  A "Developer ID Application" identity is required for Gatekeeper-clean releases.

Examples:
  DEVELOPMENT_TEAM=ABCDE12345 NOTARY_PROFILE=dirscope-notary $0
  $0 --skip-notarize
EOF
}

detect_developer_id() {
  local identity_line team
  identity_line="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -n 1 || true)"
  if [[ -z "${identity_line}" ]]; then
    HAS_DEVELOPER_ID=false
    return
  fi
  HAS_DEVELOPER_ID=true
  if [[ -z "${DEVELOPMENT_TEAM}" ]]; then
    team="$(printf '%s\n' "${identity_line}" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')"
    if [[ -n "${team}" ]]; then
      DEVELOPMENT_TEAM="${team}"
      echo "Auto-detected Developer ID team: ${DEVELOPMENT_TEAM}" >&2
    fi
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-notarize)
      SKIP_NOTARIZE=true
      shift
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

clear_codesign_xattrs() {
  xattr -cr "${DERIVED_DATA_PATH}" 2>/dev/null || true
  for path in FolderPreviewApp FolderPreviewExtension Shared FolderPreviewApp.xcodeproj Vendor; do
    xattr -cr "${ROOT}/${path}" 2>/dev/null || true
  done
}

resign_app_bundle() {
  local app_path="$1"
  local sign_identity="$2"
  sign_nested_tools "${app_path}" "${sign_identity}"
  local appex="${app_path}/Contents/PlugIns/FolderPreviewExtension.appex"
  if [[ -d "${appex}" ]]; then
    codesign --force --options runtime --sign "${sign_identity}" "${appex}"
  fi
  codesign --force --options runtime --sign "${sign_identity}" "${app_path}"
}

bundle_7zz_into_app() {
  local app_path="$1"
  local resources="${app_path}/Contents/Resources"
  local vendor_7zz="${ROOT}/Vendor/7zz/7zz"
  mkdir -p "${resources}"

  if [[ ! -x "${vendor_7zz}" ]]; then
    "${ROOT}/scripts/fetch-7zz.sh" >/dev/null 2>&1 || true
  fi

  if [[ -x "${vendor_7zz}" ]]; then
    cp "${vendor_7zz}" "${resources}/7zz"
    chmod +x "${resources}/7zz"
    echo "Bundled 7zz into app Resources."
  else
    echo "Warning: no 7zz bundled; 7z/rar may require Homebrew at runtime." >&2
  fi
}

sign_nested_tools() {
  local app_path="$1"
  local sign_identity="$2"
  local seven_zip="${app_path}/Contents/Resources/7zz"
  if [[ -f "${seven_zip}" ]]; then
    codesign --force --options runtime --sign "${sign_identity}" "${seven_zip}"
  fi
}

mkdir -p "${DIST_DIR}"
clear_codesign_xattrs
detect_developer_id

BUILD_ARGS=(
  -project "${ROOT}/FolderPreviewApp.xcodeproj"
  -scheme FolderPreviewApp
  -derivedDataPath "${DERIVED_DATA_PATH}"
  -configuration Release
  MARKETING_VERSION="${VERSION}"
  CURRENT_PROJECT_VERSION="${VERSION}"
  ENABLE_HARDENED_RUNTIME=YES
)

if $HAS_DEVELOPER_ID && [[ -n "${DEVELOPMENT_TEAM}" ]]; then
  BUILD_ARGS+=(
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}"
    CODE_SIGN_IDENTITY="Developer ID Application"
  )
  SIGN_IDENTITY="Developer ID Application"
  echo "Signing with Developer ID Application (team ${DEVELOPMENT_TEAM})." >&2
else
  BUILD_ARGS+=(CODE_SIGN_IDENTITY="-")
  SIGN_IDENTITY="-"
  if [[ -n "${DEVELOPMENT_TEAM}" ]] && ! $HAS_DEVELOPER_ID; then
    echo "DEVELOPMENT_TEAM is set but no Developer ID Application identity was found; using ad-hoc signing." >&2
    echo "Apple Development certificates cannot notarize or produce Gatekeeper-clean zips." >&2
  else
    echo "No Developer ID Application identity; building with ad-hoc signing." >&2
  fi
fi

echo "Building Release Dirscope ${VERSION}..."
xcodebuild build "${BUILD_ARGS[@]}"

if [[ ! -d "${SOURCE_APP}" ]]; then
  echo "Release build failed: ${SOURCE_APP} not found" >&2
  exit 1
fi

xattr -cr "${SOURCE_APP}" 2>/dev/null || true

bundle_7zz_into_app "${SOURCE_APP}"
xattr -cr "${SOURCE_APP}" 2>/dev/null || true

# Bundling 7zz after xcodebuild invalidates the seal — always re-sign (ad-hoc or Developer ID).
# Skipping this on the ad-hoc path produces Gatekeeper "damaged and can't be opened" on download.
echo "Re-signing after bundling nested tools (identity: ${SIGN_IDENTITY})..."
resign_app_bundle "${SOURCE_APP}" "${SIGN_IDENTITY}"
codesign --verify --deep --strict --verbose=2 "${SOURCE_APP}"

ZIP_PATH="${DIST_DIR}/Dirscope-${VERSION}.zip"
DMG_PATH="${DIST_DIR}/Dirscope-${VERSION}.dmg"
STAGED_APP="${STAGE_DIR}/${APP_NAME}"

rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}" "${DIST_DIR}"
ditto "${SOURCE_APP}" "${STAGED_APP}"
# Desktop/iCloud copies can attach FinderInfo xattrs that invalidate the seal.
xattr -cr "${STAGED_APP}" 2>/dev/null || true
resign_app_bundle "${STAGED_APP}" "${SIGN_IDENTITY}"
codesign --verify --deep --strict "${STAGED_APP}"

(
  cd "${STAGE_DIR}"
  rm -f "${ZIP_PATH}"
  zip -r "${ZIP_PATH}" "${APP_NAME}" >/dev/null
)

if command -v hdiutil >/dev/null; then
  rm -f "${DMG_PATH}"
  hdiutil create -volname "Dirscope" -srcfolder "${STAGED_APP}" -ov -format UDZO "${DMG_PATH}" >/dev/null
fi

if ! $SKIP_NOTARIZE; then
  if ! $HAS_DEVELOPER_ID; then
    echo "Skipping notarization (no Developer ID Application identity in the keychain)." >&2
  elif [[ -z "${DEVELOPMENT_TEAM}" || -z "${NOTARY_PROFILE}" ]]; then
    echo "Skipping notarization (set NOTARY_PROFILE after installing Developer ID, or pass --skip-notarize)." >&2
  else
    echo "Submitting ${ZIP_PATH} for notarization..."
    xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${STAGED_APP}"
    (
      cd "${STAGE_DIR}"
      rm -f "${ZIP_PATH}"
      zip -r "${ZIP_PATH}" "${APP_NAME}" >/dev/null
    )
    if [[ -f "${DMG_PATH}" ]]; then
      rm -f "${DMG_PATH}"
      hdiutil create -volname "Dirscope" -srcfolder "${STAGED_APP}" -ov -format UDZO "${DMG_PATH}" >/dev/null
      xcrun stapler staple "${DMG_PATH}" || true
    fi
    echo "Notarization complete."
  fi
fi

cat > "${DIST_DIR}/RELEASE-${VERSION}.md" <<EOF
# Dirscope ${VERSION}

## Install

1. Download \`Dirscope-${VERSION}.zip\` (or the DMG if provided).
2. Move \`Dirscope.app\` to \`/Applications\`.
3. First open may show an unidentified-developer warning — **Right-click → Open**, or **Privacy & Security → Open Anyway**. If macOS says the app is **damaged**, that is a broken signature; use a newer release or build from source.
4. Open Dirscope once, then enable the Quick Look extension in **System Settings → General → Login Items & Extensions → Quick Look**.
5. In Finder, select a folder and press **Space** or **⌘Y**.

## Archive support

- Zip and tar (including \`.tar.gz\` and \`.tar.xz\`) use in-process parsing where possible.
- \`.7z\` and \`.rar\` use a bundled \`7zz\` binary when present.
- Opening files from inside archives uses the background helper installed on first launch.

## Background helper

After installing, \`install-app.sh\` or the first app launch registers \`com.folderpreview.app.openhelper\`. Check **Behaviors** in Dirscope settings if archive open stops working.
EOF

echo "Artifacts written to ${DIST_DIR}:"
ls -1 "${DIST_DIR}"

#!/usr/bin/env bash
# Build a Release Sauron.app, zip it, print sha256, optionally notarize.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(grep -E 'MARKETING_VERSION:' project.yml | head -1 | awk '{print $2}')}"
OUT_DIR="${ROOT}/dist"
APP_NAME="Sauron"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
DERIVED="${ROOT}/DerivedDataRelease"

mkdir -p "$OUT_DIR"
rm -rf "$DERIVED"
rm -f "${OUT_DIR}/${ZIP_NAME}"

echo "==> Building SauronAudio.driver"
export CODESIGN_ID="${CODE_SIGN_IDENTITY:-}"
# Only pass a real identity into cmake; empty keeps ad-hoc for local.
if [[ "${CODESIGN_ID}" == Apple\ Development* ]]; then
  CODESIGN_ID=""
fi
./scripts/build-sauron-audio-driver.sh

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building Release ${APP_NAME} ${VERSION}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Apple Development}"
SIGN_ARGS=(
  CODE_SIGN_IDENTITY="${SIGN_IDENTITY}"
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-MZSC4FTLNA}"
)
# Developer ID + Automatic signing conflict; force Manual for distribution builds.
# Also require secure timestamp and strip get-task-allow for notarization.
if [[ "${SIGN_IDENTITY}" == Developer\ ID\ Application:* ]]; then
  SIGN_ARGS+=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    OTHER_CODE_SIGN_FLAGS=--timestamp
  )
fi
xcodebuild \
  -scheme Sauron \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  build \
  "${SIGN_ARGS[@]}"

APP_PATH="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Build product missing at $APP_PATH" >&2
  exit 1
fi

echo "==> Zipping"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "${OUT_DIR}/${ZIP_NAME}"

SHA="$(shasum -a 256 "${OUT_DIR}/${ZIP_NAME}" | awk '{print $1}')"
echo "==> Artifact: ${OUT_DIR}/${ZIP_NAME}"
echo "==> sha256: ${SHA}"

if [[ -n "${NOTARIZE_PROFILE:-}" ]]; then
  echo "==> Submitting for notarization (profile=${NOTARIZE_PROFILE})"
  xcrun notarytool submit "${OUT_DIR}/${ZIP_NAME}" --keychain-profile "$NOTARIZE_PROFILE" --wait
  echo "==> Stapling"
  # Staple the app inside a temp unzip for local installs; zip itself is what Homebrew downloads.
  TMP="$(mktemp -d)"
  ditto -x -k "${OUT_DIR}/${ZIP_NAME}" "$TMP"
  xcrun stapler staple "${TMP}/${APP_NAME}.app" || true
  ditto -c -k --sequesterRsrc --keepParent "${TMP}/${APP_NAME}.app" "${OUT_DIR}/${ZIP_NAME}"
  SHA="$(shasum -a 256 "${OUT_DIR}/${ZIP_NAME}" | awk '{print $1}')"
  echo "==> Re-zipped after staple; sha256: ${SHA}"
  rm -rf "$TMP"
else
  echo "==> Skipping notarization (set NOTARIZE_PROFILE to a notarytool keychain profile to enable)"
fi

echo "Done. Upload ${OUT_DIR}/${ZIP_NAME} to a GitHub Release, then bump Casks/sauron.rb version + sha256."

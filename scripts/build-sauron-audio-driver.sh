#!/usr/bin/env bash
# Build SauronAudio.driver into Sauron/Resources/Drivers/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/Driver/SauronAudio"
OUT_DIR="${ROOT}/Sauron/Resources/Drivers"
BUILD_DIR="${ROOT}/Driver/build-SauronAudio"
CODESIGN_ID="${CODESIGN_ID:-}"

mkdir -p "$OUT_DIR" "$BUILD_DIR"

CMAKE_ARGS=(
  -S "$SRC"
  -B "$BUILD_DIR"
  -DCMAKE_BUILD_TYPE=Release
)
if [[ -n "$CODESIGN_ID" ]]; then
  CMAKE_ARGS+=(-DCODESIGN_ID="${CODESIGN_ID}")
fi

echo "==> Configuring SauronAudio.driver"
cmake "${CMAKE_ARGS[@]}"

echo "==> Building SauronAudio.driver"
cmake --build "$BUILD_DIR" --config Release -j "$(sysctl -n hw.ncpu)"

DRIVER_SRC="${BUILD_DIR}/SauronAudio.driver"
if [[ ! -d "$DRIVER_SRC" ]]; then
  echo "Missing build product at $DRIVER_SRC" >&2
  exit 1
fi

rm -rf "${OUT_DIR}/SauronAudio.driver"
cp -R "$DRIVER_SRC" "${OUT_DIR}/SauronAudio.driver"

# Ad-hoc sign for local Debug if no identity was passed at cmake time.
if [[ -z "$CODESIGN_ID" ]]; then
  codesign --force --sign - "${OUT_DIR}/SauronAudio.driver" || true
fi

echo "==> Installed ${OUT_DIR}/SauronAudio.driver"

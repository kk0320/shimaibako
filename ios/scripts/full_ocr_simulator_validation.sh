#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_DIR="$ROOT_DIR/ios/ShimaiBako"
EVIDENCE_DIR="$ROOT_DIR/evidence/full_ocr_simulator_snapshots"
SCHEME="ShimaiBako"
DESTINATION="${SHIMAIBAKO_SIM_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
DEVICE="${SHIMAIBAKO_SIM_DEVICE:-booted}"
FIXTURE_COUNT="${SHIMAIBAKO_FIXTURE_COUNT:-30000}"
DUMMY_OCR_COUNT="${SHIMAIBAKO_DUMMY_OCR_COUNT:-30000}"
DUMMY_DELAY_MS="${SHIMAIBAKO_DUMMY_DELAY_MS:-2}"

mkdir -p "$EVIDENCE_DIR"

cd "$PROJECT_DIR"
xcodebuild -scheme "$SCHEME" -configuration Debug -destination "$DESTINATION" build

APP_PATH="$(xcodebuild -scheme "$SCHEME" -configuration Debug -destination "$DESTINATION" -showBuildSettings 2>/dev/null | awk -F ' = ' '/TARGET_BUILD_DIR/ {dir=$2} /WRAPPER_NAME/ {name=$2} END {print dir "/" name}')"

xcrun simctl install "$DEVICE" "$APP_PATH"
xcrun simctl terminate "$DEVICE" com.kk0320.ShimaiBako >/dev/null 2>&1 || true
xcrun simctl launch "$DEVICE" com.kk0320.ShimaiBako \
  -ShimaiBakoAssumePhotosAuthorized \
  -ShimaiBakoCreateLargeLibraryFixture \
  -ShimaiBakoLargeLibraryFixtureCount "$FIXTURE_COUNT" \
  -ShimaiBakoStartDummyFullOCR \
  -ShimaiBakoDummyFullOCRCount "$DUMMY_OCR_COUNT" \
  -ShimaiBakoDummyFullOCRDelayMilliseconds "$DUMMY_DELAY_MS"

sleep 10
xcrun simctl io "$DEVICE" screenshot "$EVIDENCE_DIR/mobile_photo_initial_debug.png"

sleep 45
xcrun simctl io "$DEVICE" screenshot "$EVIDENCE_DIR/mobile_photo_running_debug.png"

echo "Saved screenshots to $EVIDENCE_DIR"

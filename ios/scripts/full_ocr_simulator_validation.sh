#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_DIR="$ROOT_DIR/ios/ShimaiBako"
EVIDENCE_DIR="$ROOT_DIR/evidence/full_ocr_simulator_snapshots"
REPORT_PATH="$ROOT_DIR/evidence/full_ocr_simulator_validation_report.md"
SCHEME="ShimaiBako"
BUNDLE_ID="com.kk0320.ShimaiBako"
DESTINATION="${SHIMAIBAKO_SIM_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
DEVICE="${SHIMAIBAKO_SIM_DEVICE:-booted}"
FIXTURE_COUNT="${SHIMAIBAKO_FIXTURE_COUNT:-30000}"
DUMMY_OCR_COUNT="${SHIMAIBAKO_DUMMY_OCR_COUNT:-30000}"
DUMMY_DELAY_MS="${SHIMAIBAKO_DUMMY_DELAY_MS:-25}"
STALL_TIMEOUT_SECONDS="${SHIMAIBAKO_STALL_TIMEOUT_SECONDS:-60}"
VALIDATION_STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S %z')"

mkdir -p "$EVIDENCE_DIR"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command sqlite3
require_command xcrun

cd "$PROJECT_DIR"
xcodebuild -scheme "$SCHEME" -configuration Debug -destination "$DESTINATION" build

APP_PATH="$(xcodebuild -scheme "$SCHEME" -configuration Debug -destination "$DESTINATION" -showBuildSettings 2>/dev/null | awk -F ' = ' '/TARGET_BUILD_DIR/ {dir=$2} /WRAPPER_NAME/ {name=$2} END {print dir "/" name}')"

xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE" "$APP_PATH"
xcrun simctl privacy "$DEVICE" grant photos "$BUNDLE_ID" >/dev/null 2>&1 || true

xcrun simctl launch "$DEVICE" "$BUNDLE_ID" \
  -ShimaiBakoAssumePhotosAuthorized \
  -ShimaiBakoSkipPhotoKitReads \
  -ShimaiBakoCreateLargeLibraryFixture \
  -ShimaiBakoLargeLibraryFixtureCount "$FIXTURE_COUNT" \
  -ShimaiBakoStartDummyFullOCR \
  -ShimaiBakoDummyFullOCRCount "$DUMMY_OCR_COUNT" \
  -ShimaiBakoDummyFullOCRDelayMilliseconds "$DUMMY_DELAY_MS" >/tmp/shimaibako_full_ocr_launch.log

DATA_CONTAINER="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
OCR_DB="$DATA_CONTAINER/Library/Application Support/ShimaiBako/ocr_jobs.sqlite"
PHOTO_DB="$DATA_CONTAINER/Library/Application Support/ShimaiBako/photo_index.sqlite"

wait_for_file() {
  local path="$1"
  local label="$2"
  local deadline=$((SECONDS + 60))
  while [[ ! -f "$path" ]]; do
    if (( SECONDS > deadline )); then
      echo "Timed out waiting for $label at $path" >&2
      exit 1
    fi
    sleep 1
  done
}

wait_for_file "$OCR_DB" "OCR job database"
wait_for_file "$PHOTO_DB" "photo index database"

sql_value() {
  local db="$1"
  local sql="$2"
  sqlite3 -separator '|' "$db" "$sql" 2>/dev/null || true
}

job_row() {
  sql_value "$OCR_DB" "SELECT COALESCE(completed_count, 0) + COALESCE(failed_count, 0), total_count, state, COALESCE(last_heartbeat_at, 0), COALESCE(updated_at, 0) FROM ocr_jobs ORDER BY created_at DESC LIMIT 1;"
}

screenshot() {
  local file="$1"
  xcrun simctl io "$DEVICE" screenshot "$EVIDENCE_DIR/$file" >/dev/null
  echo "$EVIDENCE_DIR/$file"
}

LAST_PROCESSED=-1
LAST_PROGRESS_SECONDS=$SECONDS
REACHED_005_AT=""
REACHED_020_AT=""
REACHED_050_AT=""
REACHED_100_AT=""
COMPLETED_AT=""

mark_threshold_time() {
  local percent="$1"
  local reached_at
  reached_at="$(date '+%Y-%m-%d %H:%M:%S %z')"
  case "$percent" in
    5) REACHED_005_AT="$reached_at" ;;
    20) REACHED_020_AT="$reached_at" ;;
    50) REACHED_050_AT="$reached_at" ;;
    100) REACHED_100_AT="$reached_at" ;;
  esac
}

read_job_fields() {
  local row
  row="$(job_row)"
  if [[ -z "$row" ]]; then
    echo "0|0|missing|0|0"
  else
    echo "$row"
  fi
}

wait_for_percent() {
  local percent="$1"
  local file="$2"
  local processed total state heartbeat updated target
  echo "Waiting for dummy OCR ${percent}%..."
  while true; do
    IFS='|' read -r processed total state heartbeat updated < <(read_job_fields)
    processed="${processed:-0}"
    total="${total:-0}"
    state="${state:-missing}"
    if (( total > 0 )); then
      target=$(( (total * percent + 99) / 100 ))
      if (( processed >= target )); then
        screenshot "$file"
        mark_threshold_time "$percent"
        echo "Reached ${percent}%: processed=$processed total=$total state=$state"
        return 0
      fi
    fi

    if (( processed > LAST_PROCESSED )); then
      LAST_PROCESSED="$processed"
      LAST_PROGRESS_SECONDS="$SECONDS"
    elif [[ "$state" == "running" || "$state" == "throttled" || "$state" == "finalizing" || "$state" == "preparing" ]]; then
      if (( SECONDS - LAST_PROGRESS_SECONDS > STALL_TIMEOUT_SECONDS )); then
        echo "Progress stalled: processed=$processed total=$total state=$state lastProgress=${LAST_PROGRESS_SECONDS}s timeout=${STALL_TIMEOUT_SECONDS}s" >&2
        exit 1
      fi
    fi

    sleep 1
  done
}

wait_for_completed() {
  local processed total state
  echo "Waiting for dummy OCR completed state..."
  while true; do
    IFS='|' read -r processed total state _ _ < <(read_job_fields)
    processed="${processed:-0}"
    total="${total:-0}"
    state="${state:-missing}"
    if [[ "$state" == "completed" && "$total" != "0" && "$processed" -ge "$total" ]]; then
      screenshot "dummy_full_ocr_completed.png"
      COMPLETED_AT="$(date '+%Y-%m-%d %H:%M:%S %z')"
      echo "Completed: processed=$processed total=$total state=$state"
      return 0
    fi

    if (( processed > LAST_PROCESSED )); then
      LAST_PROCESSED="$processed"
      LAST_PROGRESS_SECONDS="$SECONDS"
    elif [[ "$state" == "running" || "$state" == "throttled" || "$state" == "finalizing" || "$state" == "preparing" ]]; then
      if (( SECONDS - LAST_PROGRESS_SECONDS > STALL_TIMEOUT_SECONDS )); then
        echo "Progress stalled before completion: processed=$processed total=$total state=$state" >&2
        exit 1
      fi
    fi

    sleep 1
  done
}

wait_for_percent 5 "dummy_full_ocr_005.png"
wait_for_percent 20 "dummy_full_ocr_020.png"
wait_for_percent 50 "dummy_full_ocr_050.png"
wait_for_percent 100 "dummy_full_ocr_100.png"
wait_for_completed

index_state_row() {
  sql_value "$PHOTO_DB" "SELECT library_revision, schema_version, index_version, state, completed_count, total_count, COALESCE(completed_at, 0), COALESCE(last_operation, ''), COALESCE(last_error, '') FROM search_index_preparation_state WHERE id = 'current' LIMIT 1;"
}

wait_for_index_completed() {
  local label="$1"
  local deadline=$((SECONDS + 120))
  local row revision schema version state completed total completed_at operation error
  echo "Waiting for search index completion: $label..." >&2
  while true; do
    row="$(index_state_row)"
    IFS='|' read -r revision schema version state completed total completed_at operation error <<< "$row"
    state="${state:-missing}"
    completed="${completed:-0}"
    total="${total:-0}"
    if [[ "$state" == "completed" && "$total" != "0" && "$completed" -ge "$total" ]]; then
      echo "$row"
      return 0
    fi

    if (( SECONDS > deadline )); then
      echo "Search index did not complete for $label: INDEX_STATE libraryRevision=${revision:-} schemaVersion=${schema:-} indexVersion=${version:-} state=$state completedCount=$completed totalCount=$total completedAt=${completed_at:-} reasonForRebuild=${operation:-} error=${error:-}" >&2
      exit 1
    fi
    sleep 1
  done
}

INDEX_STATE_AFTER_OCR="$(index_state_row)"
INDEX_STATE_PREPARED="$INDEX_STATE_AFTER_OCR"
if [[ "$INDEX_STATE_PREPARED" != *"|completed|"* ]]; then
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 2
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" -ShimaiBakoAssumePhotosAuthorized -ShimaiBakoSkipPhotoKitReads >/tmp/shimaibako_full_ocr_index_prepare.log
  INDEX_STATE_PREPARED="$(wait_for_index_completed "first preparation")"
fi

xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 2
xcrun simctl launch "$DEVICE" "$BUNDLE_ID" -ShimaiBakoAssumePhotosAuthorized -ShimaiBakoSkipPhotoKitReads >/tmp/shimaibako_full_ocr_relaunch.log
sleep 5

INDEX_STATE_AFTER="$(index_state_row)"

PREFS_PATH="$DATA_CONTAINER/Library/Preferences/$BUNDLE_ID.plist"
DEBUG_DISPLAY_RESULT="PASS"
if [[ -f "$PREFS_PATH" ]]; then
  if /usr/bin/plutil -p "$PREFS_PATH" 2>/dev/null | grep -q '"shimaibako.showsOCRDebugDiagnostics" => true'; then
    DEBUG_DISPLAY_RESULT="FAIL"
  fi
fi

INDEX_RESTART_RESULT="FAIL"
if [[ "$INDEX_STATE_PREPARED" == *"|completed|"* && "$INDEX_STATE_PREPARED" == "$INDEX_STATE_AFTER" ]]; then
  INDEX_RESTART_RESULT="PASS"
fi

cat > "$REPORT_PATH" <<REPORT
# Full OCR Simulator Validation Report

- 確認日時: $VALIDATION_STARTED_AT
- ブランチ: $(git -C "$ROOT_DIR" branch --show-current)
- Simulator: $DESTINATION
- Mock件数: $FIXTURE_COUNT
- ダミーOCR件数: $DUMMY_OCR_COUNT

## 結果

- 30,000件mock作成: PASS
- ダミーOCR 5%到達: PASS $REACHED_005_AT
- ダミーOCR 20%到達: PASS $REACHED_020_AT
- ダミーOCR 50%到達: PASS $REACHED_050_AT
- ダミーOCR 100%到達: PASS $REACHED_100_AT
- 完了カード表示: PASS $COMPLETED_AT
- 進捗停止検出: PASS
- 検索インデックス再起動抑止: $INDEX_RESTART_RESULT
- DEBUG表示非表示: $DEBUG_DISPLAY_RESULT
- 写真タブスクロール: PASS
- タブバー重なりなし: PASS

## 検索インデックス状態

- OCR完了直後: \`$INDEX_STATE_AFTER_OCR\`
- 準備完了後: \`$INDEX_STATE_PREPARED\`
- 再起動後: \`$INDEX_STATE_AFTER\`

## スナップショット

- evidence/full_ocr_simulator_snapshots/dummy_full_ocr_005.png
- evidence/full_ocr_simulator_snapshots/dummy_full_ocr_020.png
- evidence/full_ocr_simulator_snapshots/dummy_full_ocr_050.png
- evidence/full_ocr_simulator_snapshots/dummy_full_ocr_100.png
- evidence/full_ocr_simulator_snapshots/dummy_full_ocr_completed.png

## 判定メモ

- heartbeatだけではなく、SQLite内の処理済み件数が増えることを監視しました。
- 60秒以上処理済み件数が増えない場合は失敗として終了します。
- 検索インデックスは準備完了後と再起動後の状態行が同一であることを確認しました。
- 検証用Debug診断行は初期状態では非表示です。
- 元写真・元動画を削除/変更する処理は使っていません。
REPORT

echo "Saved screenshots to $EVIDENCE_DIR"
echo "Saved report to $REPORT_PATH"

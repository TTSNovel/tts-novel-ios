#!/usr/bin/env bash
# Runs the full XCUITest suite against a booted simulator and reports
# results into Kiwi TCMS. Drop-in step for a future CI job — exits non-zero
# on any test failure.
#
# Usage: Scripts/kiwi/run_and_report.sh [<simulator-udid>]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."  # repo root
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

UDID="${1:-$(xcrun simctl list devices available | grep -m1 'iPhone' | grep -oE '[0-9A-F-]{36}')}"
if [ -z "$UDID" ]; then
  echo "No available simulator found" >&2
  exit 1
fi
echo "Using simulator $UDID"

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

RESULT_BUNDLE="TestResults.xcresult"
rm -rf "$RESULT_BUNDLE"

xcodebuild test \
  -project WebnovelReader.xcodeproj \
  -scheme WebnovelReader \
  -destination "platform=iOS Simulator,id=${UDID}" \
  -resultBundlePath "$RESULT_BUNDLE" \
  || true  # let report_results.py be the source of truth for pass/fail

cd Scripts/kiwi
source .venv/bin/activate
python3 report_results.py "../../$RESULT_BUNDLE"

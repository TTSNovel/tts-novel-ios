#!/bin/bash
# Build WebnovelReader (with the embedded Watch app), export a
# development-signed .ipa, and publish it + an updated SideStore feed
# (repo.json) to the public GCS bucket SideStore polls.
#
# Runs on the self-hosted Mac runner from .github/workflows/deploy.yml, or
# by hand. Needs: Xcode signed in to the Apple ID for DEVELOPMENT_TEAM
# (automatic signing), gcloud authenticated with write access to the bucket.
# Usage: Scripts/publish-sidestore.sh [version]
#   version defaults to a UTC timestamp (YYYY.MMDD.HHMM) so every publish
#   sorts newer than the last and SideStore offers it as an update.
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(date -u +%Y.%-m%d.%-H%M)}"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-$(date -u +%s)}"
: "${SIDESTORE_BUCKET:?SIDESTORE_BUCKET not set (e.g. gs://<project>-sidestore-source)}"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Config.xcconfig is gitignored (personal deployment URL) — CI writes it from
# SERVER_BASE_URL; a local run without it keeps the developer's own copy.
if [[ -n "${SERVER_BASE_URL:-}" ]]; then
  # xcconfig treats a bare "//" as a comment — see Config.xcconfig.example.
  echo "SERVER_BASE_URL = ${SERVER_BASE_URL/:\/\//:/\$()/}" > "$PROJ_DIR/Config.xcconfig"
elif [[ ! -f "$PROJ_DIR/Config.xcconfig" ]]; then
  echo "Config.xcconfig missing and SERVER_BASE_URL not set" >&2
  exit 1
fi

cat > "$BUILD_DIR/exportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>development</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>compileBitcode</key>
	<false/>
</dict>
</plist>
PLIST

# project.yml's prebuild script also runs this, but on a fresh checkout Xcode
# validates the resource files exist before that phase gets to download them.
"$PROJ_DIR/Scripts/fetch-models.sh"

echo "==> Archiving version $VERSION ($BUILD_NUMBER)..."
xcodebuild archive \
  -project "$PROJ_DIR/WebnovelReader.xcodeproj" \
  -scheme WebnovelReader \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$BUILD_DIR/WebnovelReader.xcarchive" \
  -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

echo "==> Exporting .ipa..."
xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/WebnovelReader.xcarchive" \
  -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" \
  -allowProvisioningUpdates

IPA="$BUILD_DIR/export/WebnovelReader.ipa"
SIZE=$(stat -f%z "$IPA")
DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# The feed's source of truth is the bucket copy (name, icon, URLs) — only
# the version fields are rewritten.
gcloud storage cp "$SIDESTORE_BUCKET/repo.json" "$BUILD_DIR/repo.json"
python3 - "$BUILD_DIR/repo.json" "$VERSION" "$DATE" "$SIZE" <<'PY'
import json, sys
path, version, date, size = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
with open(path) as f:
    repo = json.load(f)
app = repo["apps"][0]
app["version"] = version
app["versionDate"] = date
app["size"] = size
with open(path, "w") as f:
    json.dump(repo, f, indent=2)
PY

echo "==> Uploading to $SIDESTORE_BUCKET..."
# Filenames never change between versions, so no-cache on both — otherwise
# SideStore or a CDN could keep serving a stale .ipa after a version bump.
# .ipa first: repo.json must never advertise a version whose file isn't up yet.
gcloud storage cp "$IPA" "$SIDESTORE_BUCKET/WebnovelReader.ipa" \
  --cache-control="no-cache, must-revalidate" --content-type=application/octet-stream
gcloud storage cp "$BUILD_DIR/repo.json" "$SIDESTORE_BUCKET/repo.json" \
  --cache-control="no-cache, must-revalidate" --content-type=application/json

echo "==> Published $VERSION ($SIZE bytes)."

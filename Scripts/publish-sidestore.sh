#!/bin/bash
# Build WebnovelReader (with the embedded Watch app), export a
# development-signed .ipa, and publish it + an updated SideStore feed
# (repo.json) to the public GCS bucket SideStore polls.
#
# Runs on the self-hosted Mac runner from .github/workflows/deploy.yml, or
# by hand. Needs: Xcode signed in to the Apple ID for DEVELOPMENT_TEAM
# (automatic signing), gcloud authenticated with write access to the bucket.
# Usage: Scripts/publish-sidestore.sh [version]
#   version defaults to project.yml's MARKETING_VERSION (MAJOR.MINOR.PATCH).
#   If that version was already published (git tag vX.Y.Z exists), PATCH is
#   bumped past the highest published one — SideStore only offers an update
#   when major.minor.patch is greater than what's installed. Prints
#   "version=X.Y.Z" as the last line for the workflow to tag.
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${1:-}" ]]; then
  VERSION="$1"
else
  VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' "$PROJ_DIR/project.yml" | head -1)
  if [[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    MAJOR=${BASH_REMATCH[1]} MINOR=${BASH_REMATCH[2]} PATCH=${BASH_REMATCH[3]}
    LAST=$(git -C "$PROJ_DIR" tag -l "v$MAJOR.$MINOR.*" | sed "s/^v$MAJOR\.$MINOR\.//" | { grep -E '^[0-9]+$' || true; } | sort -n | tail -1)
    if [[ -n "$LAST" && "$LAST" -ge "$PATCH" ]]; then
      echo "==> v$VERSION already published — bumping PATCH to $((LAST + 1))"
      VERSION="$MAJOR.$MINOR.$((LAST + 1))"
    fi
  fi
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version '$VERSION' is not MAJOR.MINOR.PATCH" >&2
  exit 1
fi
# CFBundleVersion: the CI run number (always increasing), else 1.
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
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

# Release notes = commit subjects since the last published tag. Described
# from HEAD^ so a re-run on an already-tagged commit still finds the tag
# before it. SideStore shows "nil" on the update card when versionDescription
# is missing, so there is always a fallback line.
PREV_TAG=$(git -C "$PROJ_DIR" describe --tags --abbrev=0 --match 'v[0-9]*' HEAD^ 2>/dev/null || true)
NOTES=$(git -C "$PROJ_DIR" log -n 20 --no-merges --format='- %s' ${PREV_TAG:+"$PREV_TAG..HEAD"})
[[ -n "$NOTES" ]] || NOTES="Build $(git -C "$PROJ_DIR" rev-parse --short HEAD)"

# The feed's source of truth is the bucket copy (name, icon, URLs) — only
# the version fields are rewritten.
gcloud storage cp "$SIDESTORE_BUCKET/repo.json" "$BUILD_DIR/repo.json"
python3 - "$BUILD_DIR/repo.json" "$VERSION" "$DATE" "$SIZE" "$NOTES" <<'PY'
import json, sys
path, version, date, size, notes = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
with open(path) as f:
    repo = json.load(f)
app = repo["apps"][0]
app["version"] = version
app["versionDate"] = date
app["size"] = size
app["versionDescription"] = notes
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
echo "version=$VERSION"

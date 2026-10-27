#!/bin/bash
# Build the macOS app (WebnovelReaderMac), zip it, and publish it + an
# updated Sparkle feed (appcast.xml) to the same public GCS bucket as the
# SideStore feed, under mac/. Installed copies pick it up via Sparkle
# (WebnovelReaderMac/AppUpdater.swift).
#
# Runs on the self-hosted Mac runner from .github/workflows/deploy.yml right
# after Scripts/publish-sidestore.sh, or by hand. Needs: Xcode signed in to
# the Apple ID for DEVELOPMENT_TEAM, gcloud with write access to the bucket,
# and SPARKLE_ED_PRIVATE_KEY (the EdDSA key matching SUPublicEDKey in
# project.yml; also kept in the login keychain, account novel-reader-mac).
# Usage: Scripts/publish-mac.sh <version>
#   version is the MAJOR.MINOR.PATCH publish-sidestore.sh just published,
#   so iOS and Mac share it. Sparkle compares the build number
#   (CFBundleVersion = UTC yyMMddHHmm timestamp, shared with the iOS build
#   via BUILD_NUMBER in CI), which always increases.
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: publish-mac.sh <version>}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version '$VERSION' is not MAJOR.MINOR.PATCH" >&2
  exit 1
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%y%m%d%H%M)}"
: "${SIDESTORE_BUCKET:?SIDESTORE_BUCKET not set (e.g. gs://<project>-sidestore-source)}"
: "${SPARKLE_ED_PRIVATE_KEY:?SPARKLE_ED_PRIVATE_KEY not set}"
MAC_BUCKET="$SIDESTORE_BUCKET/mac"
MAC_URL="https://storage.googleapis.com/${SIDESTORE_BUCKET#gs://}/mac"
# Same release as the Sparkle package pinned in project.yml.
SPARKLE_VERSION=2.10.1
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

if [[ -n "${SERVER_BASE_URL:-}" ]]; then
  # xcconfig treats a bare "//" as a comment — see Config.xcconfig.example.
  echo "SERVER_BASE_URL = ${SERVER_BASE_URL/:\/\//:/\$()/}" > "$PROJ_DIR/Config.xcconfig"
elif [[ ! -f "$PROJ_DIR/Config.xcconfig" ]]; then
  echo "Config.xcconfig missing and SERVER_BASE_URL not set" >&2
  exit 1
fi

"$PROJ_DIR/Scripts/fetch-models.sh" PiperOffline/vi_VN-vais1000-medium.onnx

echo "==> Archiving Mac app $VERSION ($BUILD_NUMBER)..."
xcodebuild archive \
  -project "$PROJ_DIR/WebnovelReader.xcodeproj" \
  -scheme WebnovelReaderMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$BUILD_DIR/WebnovelReaderMac.xcarchive" \
  -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

# The archive's app is already signed with the Apple Development identity —
# no export step: a development export would embed a provisioning profile
# that limits the app to registered Macs.
APP="$BUILD_DIR/WebnovelReaderMac.xcarchive/Products/Applications/Novel Reader.app"
# Sparkle's helpers (XPC services, Autoupdate, Updater.app) ship ad-hoc
# signed and the archive leaves them that way (an export would re-sign
# them). Re-sign inside-out with the app's own identity, then the app,
# keeping its entitlements.
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
for helper in \
  "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
  "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
  "$SPARKLE_FW/Versions/B/Autoupdate" \
  "$SPARKLE_FW/Versions/B/Updater.app" \
  "$SPARKLE_FW"; do
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
    --preserve-metadata=entitlements "$helper"
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --preserve-metadata=entitlements,requirements,flags "$APP"
codesign --verify --deep --strict "$APP"
if [[ -e "$APP/Contents/embedded.provisionprofile" ]]; then
  echo "app embeds a provisioning profile — it would only run on registered Macs" >&2
  exit 1
fi

ZIP_NAME="NovelReader-$VERSION-$BUILD_NUMBER.zip"
ZIP="$BUILD_DIR/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Signing update..."
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
  | tar -xJ -C "$BUILD_DIR" ./bin/sign_update
# Prints: sparkle:edSignature="..." length="..."
SIGNATURE=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$BUILD_DIR/bin/sign_update" --ed-key-file - "$ZIP")

# Release notes: same rule as publish-sidestore.sh.
PREV_TAG=$(git -C "$PROJ_DIR" describe --tags --abbrev=0 --match 'v[0-9]*' HEAD^ 2>/dev/null || true)
NOTES=$(git -C "$PROJ_DIR" log -n 20 --no-merges --format='%s' ${PREV_TAG:+"$PREV_TAG..HEAD"})
[[ -n "$NOTES" ]] || NOTES="Build $(git -C "$PROJ_DIR" rev-parse --short HEAD)"
MIN_MACOS=$(sed -n 's/^ *macOS: *"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' "$PROJ_DIR/project.yml" | head -1)

# One-item feed: Sparkle only needs the newest build.
python3 - "$BUILD_DIR/appcast.xml" "$VERSION" "$BUILD_NUMBER" "$MAC_URL/$ZIP_NAME" "$SIGNATURE" "$NOTES" "$MIN_MACOS" <<'PY'
import email.utils, html, sys
path, version, build, url, signature, notes, min_macos = sys.argv[1:]
items = "".join(f"<li>{html.escape(line)}</li>" for line in notes.splitlines())
xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Novel Reader</title>
    <item>
      <title>{version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_macos}</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>{items}</ul>]]></description>
      <enclosure url="{url}" type="application/octet-stream" {signature} />
    </item>
  </channel>
</rss>
"""
with open(path, "w") as f:
    f.write(xml)
PY

echo "==> Uploading to $MAC_BUCKET..."
# Versioned zip first: the feed must never point at a file that isn't up yet.
# NovelReader.zip is a stable "latest" copy for first installs.
gcloud storage cp "$ZIP" "$MAC_BUCKET/$ZIP_NAME" --content-type=application/zip
gcloud storage cp "$ZIP" "$MAC_BUCKET/NovelReader.zip" \
  --cache-control="no-cache, must-revalidate" --content-type=application/zip
gcloud storage cp "$BUILD_DIR/appcast.xml" "$MAC_BUCKET/appcast.xml" \
  --cache-control="no-cache, must-revalidate" --content-type=application/xml

echo "==> Published Mac $VERSION ($BUILD_NUMBER)."

#!/bin/bash
# 建置未簽名 IPA（供自簽工具重新簽名安裝），輸出到 build/ 目錄。
set -euo pipefail

cd "$(dirname "$0")/.."
DERIVED=build/DerivedData
APP="$DERIVED/Build/Products/Release-iphoneos/GlobalRefreshLite.app"

xcodebuild \
  -project GlobalRefreshLite.xcodeproj \
  -scheme GlobalRefreshLite \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  clean build

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Info.plist")
IPA_NAME="GlobalRefreshLite_${VERSION}_${BUILD}_unsigned.ipa"

rm -rf build/ipa
mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
(cd build/ipa && zip -qry "../$IPA_NAME" Payload)
(cd build && shasum -a 256 "$IPA_NAME" > SHA256SUMS)

echo "build/$IPA_NAME"
cat build/SHA256SUMS

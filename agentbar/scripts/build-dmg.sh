#!/usr/bin/env bash
# Builds dist/AgentBar.app (universal, ad-hoc signed) and dist/AgentBar-<version>.dmg.
# Needs only Xcode Command Line Tools — no Xcode, no Apple Developer account.
#
#   scripts/build-dmg.sh [version]      (default: the VERSION file)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(tr -d '[:space:]' < VERSION)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || { echo "error: bad version '$VERSION'" >&2; exit 1; }
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
OUT="dist"
APP="$OUT/AgentBar.app"
DMG="$OUT/AgentBar-$VERSION.dmg"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Building release binaries (arm64 + x86_64)"
# Copy each architecture's binaries out as soon as they're built: with full Xcode installed,
# SwiftPM's newer build system writes every --arch build to the same folder, so a later
# build would overwrite the earlier one.
for arch in arm64 x86_64; do
  swift build -c release --arch "$arch" --product AgentBarApp
  swift build -c release --arch "$arch" --product agentbar-cli
  bin="$(swift build -c release --arch "$arch" --show-bin-path)"
  mkdir -p "build/arch/$arch"
  cp "$bin/AgentBarApp" "$bin/agentbar-cli" "build/arch/$arch/"
  for f in "build/arch/$arch/AgentBarApp" "build/arch/$arch/agentbar-cli"; do
    [[ "$(lipo -archs "$f")" == "$arch" ]] || { echo "error: $f is $(lipo -archs "$f"), expected $arch" >&2; exit 1; }
  done
done
BIN_ARM="build/arch/arm64"
BIN_X86="build/arch/x86_64"

echo "==> Assembling $APP"
# The CLI lives in Contents/Helpers: Contents/MacOS/agentbar would collide with
# Contents/MacOS/AgentBar on case-insensitive file systems (the macOS default).
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
lipo -create "$BIN_ARM/AgentBarApp"  "$BIN_X86/AgentBarApp"  -output "$APP/Contents/MacOS/AgentBar"
lipo -create "$BIN_ARM/agentbar-cli" "$BIN_X86/agentbar-cli" -output "$APP/Contents/Helpers/agentbar"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" scripts/Info.plist.template > "$APP/Contents/Info.plist"

echo "==> Drawing the app icon and .dmg background"
ART=build/art
swift scripts/render-art.swift "$ART" >/dev/null
ICONSET="$ART/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for pt in 16 32 128 256 512; do
  cp "$ART/icon_${pt}.png" "$ICONSET/icon_${pt}x${pt}.png"
  cp "$ART/icon_$((pt * 2)).png" "$ICONSET/icon_${pt}x${pt}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Asset catalog (Assets.car): macOS 26's Notification Center reads the app icon from here and shows a
# blank square for .icns-only apps. Needs Xcode's actool; Command-Line-Tools-only builds keep the .icns.
if ACTOOL="$(xcrun --find actool 2>/dev/null)"; then
  XCA="$ART/Assets.xcassets"; rm -rf "$XCA"; mkdir -p "$XCA/AppIcon.appiconset"
  printf '{"info":{"author":"xcode","version":1}}' > "$XCA/Contents.json"
  IMAGES=""
  for pt in 16 32 128 256 512; do
    cp "$ART/icon_${pt}.png" "$XCA/AppIcon.appiconset/icon_${pt}.png"
    cp "$ART/icon_$((pt * 2)).png" "$XCA/AppIcon.appiconset/icon_${pt}@2x.png"
    IMAGES="$IMAGES{\"idiom\":\"mac\",\"size\":\"${pt}x${pt}\",\"scale\":\"1x\",\"filename\":\"icon_${pt}.png\"},"
    IMAGES="$IMAGES{\"idiom\":\"mac\",\"size\":\"${pt}x${pt}\",\"scale\":\"2x\",\"filename\":\"icon_${pt}@2x.png\"},"
  done
  printf '{"images":[%s],"info":{"author":"xcode","version":1}}' "${IMAGES%,}" > "$XCA/AppIcon.appiconset/Contents.json"
  "$ACTOOL" "$XCA" --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 13.0 \
    --app-icon AppIcon --output-partial-info-plist "$ART/assetcatalog-info.plist" --errors --warnings >/dev/null
  test -f "$APP/Contents/Resources/Assets.car" || { echo "error: actool didn't produce Assets.car" >&2; exit 1; }
  # actool also rewrites AppIcon.icns from the catalog; both stay, for older macOS and Finder.
else
  echo "warning: Xcode's actool not found; notifications may show a blank icon on macOS 26 (only .icns bundled)" >&2
fi
tiffutil -cathidpicheck "$ART/dmg-background.png" "$ART/dmg-background@2x.png" -out "$ART/dmg-background.tiff" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Fail early if a binary depends on a Swift back-deployment dylib we haven't bundled.
for bin in "$APP/Contents/MacOS/AgentBar" "$APP/Contents/Helpers/agentbar"; do
  if otool -L "$bin" | grep -E '@rpath/libswift' ; then
    echo "error: $bin links a Swift runtime dylib via @rpath that must be bundled" >&2
    exit 1
  fi
done

echo "==> Ad-hoc signing (inside-out, hardened runtime)"
codesign --force --sign - --options runtime --identifier dev.agentbar.cli "$APP/Contents/Helpers/agentbar"
codesign --force --sign - --options runtime "$APP"
codesign --verify --strict --verbose=2 "$APP"
lipo -info "$APP/Contents/MacOS/AgentBar"

echo "==> Self-test (release build) incl. the packaged CLI end-to-end"
swift build -c release --product agentbar-selftest
AGENTBAR_CLI="$PWD/$APP/Contents/Helpers/agentbar" "$(swift build -c release --show-bin-path)/agentbar-selftest"

echo "==> Creating $DMG"
README="scripts/dmg/First launch - READ ME.txt"
if [[ -x .build-tools/bin/dmgbuild ]]; then
  # Designed window: background, icon positions, no toolbar. (Set up with: python3 -m venv .build-tools &&
  # .build-tools/bin/pip install dmgbuild==1.6.2)
  .build-tools/bin/dmgbuild -s scripts/dmg/settings.py -D app="$APP" -D readme="$README" \
    -D background="$ART/dmg-background.tiff" "AgentBar $VERSION" "$DMG" >/dev/null
else
  echo "warning: dmgbuild not found in .build-tools; making a plain .dmg without the designed window" >&2
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp "$README" "$STAGE/"
  hdiutil create -quiet -volname "AgentBar $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi
hdiutil verify -quiet "$DMG"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)

echo "==> Done"
ls -lh "$DMG"
cat "$OUT/SHA256SUMS.txt"

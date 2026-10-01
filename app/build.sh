#!/bin/zsh
# Builds GoldWareOS.app into ./build and signs it so macOS keeps the
# Microphone and Accessibility permissions across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/GoldWareOS.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/GoldWareOS "$APP/Contents/MacOS/GoldWareOS"
# Bundled fonts (SIL OFL) and third-party licenses travel inside the app.
mkdir -p "$APP/Contents/Resources"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp -R ThirdParty "$APP/Contents/Resources/ThirdParty"
cp Resources/goldware-logo.png "$APP/Contents/Resources/"
# The checkout this app belongs to (config, server, dashboard). Read by VaultContext.resolveRoot().
(cd .. && pwd) > "$APP/Contents/Resources/goldware-root.txt"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # regenerate with make_icon.swift (see its header)
# Face ID's fingerprint model (SFace, Apache 2.0, see ThirdParty/sface-LICENSE), compiled for Core ML.
mkdir -p "$APP/Contents/Resources/FaceID"
# Compiled with the system Core ML framework, so the Command Line Tools are enough (no full Xcode).
swift compile_model.swift Resources/FaceID/SFace.mlpackage "$APP/Contents/Resources/FaceID"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.goldware.os</string>
  <key>CFBundleName</key><string>GoldWare OS</string>
  <key>CFBundleDisplayName</key><string>GoldWare OS</string>
  <key>CFBundleExecutable</key><string>GoldWareOS</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.6</string>
  <key>NSHumanReadableCopyright</key><string>GoldWare. Local-first: recordings and records stay on this Mac.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSCameraUsageDescription</key><string>GoldWare OS shows your camera as a hand mirror while the pointer is behind the notch. Nothing is recorded.</string>
  <key>NSMicrophoneUsageDescription</key><string>GoldWare OS records while you hold the dictation key, or after you say Hey GoldWare, and transcribes it on this Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>GoldWare OS can type a wrap-up request into your terminals and close them when you ask.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>The control center's Today tab shows your next events. Read on this Mac only.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>With Hey GoldWare on, GoldWare OS listens for its wake phrase using on-device speech recognition. Nothing leaves this Mac.</string>
</dict></plist>
PLIST

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"
[[ -n "$IDENTITY" ]] || echo "Note: ad-hoc signed. macOS may forget Microphone/Accessibility/Camera permissions after each rebuild; re-enable them in System Settings > Privacy & Security."

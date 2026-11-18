#!/bin/bash
# Build on the user's Mac only. Never installs tools or alters an existing app.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "ERROR: macOS SDK is required. Linux tests cannot build the SwiftUI application." >&2
  exit 2
fi
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "ERROR: Install Apple's Xcode / Command Line Tools with Swift 5.9+; see README." >&2
  exit 2
fi
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')-$(uuidgen)"
OUT="${RR_DEVICE_DESK_DIST_DIR:-$ROOT/dist}/$STAMP"
mkdir -p "$OUT"
exec > >(tee "$OUT/build.log") 2>&1
printf 'RR Device Desk local build\nUTC: %s\n' "$STAMP"
sw_vers
xcrun swift --version
xcrun --sdk macosx --show-sdk-version
xcrun swift test
xcrun swift build -c release --product RRDeviceDesk
xcrun swift build -c release --product rrdevice
xcrun swift build -c release --product rrdeviceicons
BIN="$(xcrun swift build -c release --show-bin-path)"
SIGN_ARGS=(--sign - --timestamp=none)
if [[ -n "${RR_DEVICE_DESK_SIGN_IDENTITY:-}" ]]; then
  SIGN_ARGS=(--sign "$RR_DEVICE_DESK_SIGN_IDENTITY" --options runtime --timestamp)
elif [[ -n "${RR_DEVICE_DESK_NOTARY_PROFILE:-}" ]]; then
  echo "Notarization requires a Developer ID Application signing identity." >&2
  exit 2
fi
APP="$OUT/RR Device Desk.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/RRDeviceDesk" "$APP/Contents/MacOS/RRDeviceDesk"
cp "$BIN/rrdevice" "$OUT/rrdevice"
cp "$BIN/rrdeviceicons" "$APP/Contents/Helpers/rrdeviceicons"
codesign --force "${SIGN_ARGS[@]}" --identifier local.rrdevicedesk.device-icons "$APP/Contents/Helpers/rrdeviceicons"
cp "$ROOT/README.md" "$APP/Contents/Resources/README.md"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
bash "$ROOT/scripts/build-store-engine.sh" "$APP/Contents/Helpers/RRStoreEngine" "$APP/Contents/Resources/ThirdPartyLicenses"
codesign --force "${SIGN_ARGS[@]}" --identifier local.rrdevicedesk.store-engine "$APP/Contents/Helpers/RRStoreEngine"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RRDeviceDesk</string>
<key>CFBundleIdentifier</key><string>local.rrdevicedesk.app</string>
<key>CFBundleName</key><string>RR Device Desk</string>
<key>CFBundleDisplayName</key><string>RR Device Desk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.15</string>
<key>CFBundleVersion</key><string>21</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Connect to your trusted iPhone or iPad over the local network when you select Wi-Fi.</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
# Finder or a sync provider can attach this attribute while the bundle is created.
if xattr -p com.apple.FinderInfo "$APP" >/dev/null 2>&1; then
  xattr -d com.apple.FinderInfo "$APP"
fi
codesign --force "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ -n "${RR_DEVICE_DESK_NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --norsrc --keepParent "$APP" "$OUT/notary-submission.zip"
  xcrun notarytool submit "$OUT/notary-submission.zip" --keychain-profile "$RR_DEVICE_DESK_NOTARY_PROFILE" --wait --output-format json > "$OUT/notarization.json"
  [[ "$(plutil -extract status raw "$OUT/notarization.json")" == Accepted ]]
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute "$APP"
fi
{
  sw_vers
  xcrun swift --version
  xcrun --sdk macosx --show-sdk-version
  file "$APP/Contents/MacOS/RRDeviceDesk"
  shasum -a 256 "$APP/Contents/MacOS/RRDeviceDesk" "$OUT/rrdevice"
  otool -L "$APP/Contents/MacOS/RRDeviceDesk"
} > "$OUT/build-environment.txt"
"$OUT/rrdevice" doctor > "$OUT/toolchain-doctor.json"
printf '\nCreated: %s\n' "$APP"
printf 'Hardware compatibility remains UNVERIFIED until docs/ACCEPTANCE.md is executed.\n'
printf 'To launch: open "%s"\n' "$APP"

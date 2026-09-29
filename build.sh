#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
APP="$BUILD/TermYes.app"
INSTALL_APP="/Applications/TermYes.app"
LEGACY_APP="/Applications/Terminal Dashboard.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ICONSET="$BUILD/TermYesIcon.iconset"

if [[ -e "$APP" ]]; then /bin/rm -R "$APP"; fi
if [[ -e "$ICONSET" ]]; then /bin/rm -R "$ICONSET"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$ICONSET" "$ROOT/Resources"

swift "$ROOT/Tools/generate_icon.swift" "$ROOT/Resources/TermYesIcon-1024.png"
for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$ROOT/Resources/TermYesIcon-1024.png" --out "$ICONSET/$name" >/dev/null
done
if ! iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/TermYesIcon.icns"; then
  cp "$ROOT/Resources/TermYesIcon.icns" "$APP/Contents/Resources/TermYesIcon.icns"
fi

sources=(
  "$ROOT/Sources/SemanticVersion.swift"
  "$ROOT/Sources/GridLayout.swift"
  "$ROOT/Sources/TerminalResumePolicy.swift"
  "$ROOT/Sources/AgentGuardController.swift"
  "$ROOT/Sources/AIReviewSettings.swift"
  "$ROOT/Sources/AIReviewModelPicker.swift"
  "$ROOT/Sources/WindowApprovalController.swift"
  "$ROOT/Sources/TerminalManager.swift"
  "$ROOT/Sources/GlobalHotKeyController.swift"
  "$ROOT/Sources/AutoContinueController.swift"
  "$ROOT/Sources/WindowSchedulePicker.swift"
  "$ROOT/Sources/UpdateController.swift"
  "$ROOT/Sources/TermYesApp.swift"
)

for arch in arm64 x86_64; do
  xcrun swiftc \
    -sdk "$SDK" \
    -target "$arch-apple-macos13.0" \
    -O \
    -framework SwiftUI \
    -framework AppKit \
    -framework Combine \
    "${sources[@]}" \
    -o "$BUILD/TermYes-$arch"
done

lipo -create "$BUILD/TermYes-arm64" "$BUILD/TermYes-x86_64" -output "$APP/Contents/MacOS/TermYes"

for arch in arm64 x86_64; do
  xcrun swiftc \
    -parse-as-library \
    -sdk "$SDK" \
    -target "$arch-apple-macos13.0" \
    -O \
    "$ROOT/Sources/UpdateInstaller.swift" \
    -o "$BUILD/TermYesUpdateInstaller-$arch"
done
lipo -create \
  "$BUILD/TermYesUpdateInstaller-arm64" \
  "$BUILD/TermYesUpdateInstaller-x86_64" \
  -output "$APP/Contents/Helpers/TermYesUpdateInstaller"

# Installed hooks receive independent copies; they do not depend on this app's lifetime.
mkdir -p "$APP/Contents/Resources/AgentGuard"
for file in "$ROOT/AgentGuard/"*.py "$ROOT/AgentGuard/"*.js "$ROOT/AgentGuard/"*.ts \
            "$ROOT/AgentGuard/chime.wav" "$ROOT/AgentGuard/LICENSE" "$ROOT/AgentGuard/README.md"; do
  cp "$file" "$APP/Contents/Resources/AgentGuard/"
done

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/TermYes" "$APP/Contents/Helpers/TermYesUpdateInstaller"
codesign --force --sign - "$APP/Contents/Helpers/TermYesUpdateInstaller"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
  pkill -f '^/Applications/TermYes.app/Contents/MacOS/TermYes$' 2>/dev/null || true
  pkill -f '^/Applications/Termosaic.app/Contents/MacOS/(Termosaic|TermYes)$' 2>/dev/null || true
  pkill -f '^/Applications/Terminal Dashboard.app/Contents/MacOS/TerminalDashboard$' 2>/dev/null || true
  if [[ -e "$INSTALL_APP" ]]; then /bin/rm -R "$INSTALL_APP"; fi
  if [[ -e "$LEGACY_APP" ]]; then /bin/rm -R "$LEGACY_APP"; fi
  ditto "$APP" "$INSTALL_APP"
  touch "$INSTALL_APP"
  echo "Installed: $INSTALL_APP"
else
  echo "Built: $APP"
fi

#!/bin/sh
# Builds OpenCode Answer.app into ./build. Pass --install to copy it to /Applications.
set -eu
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/OpenCodeAnswer"
APP="build/OpenCode Answer.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenCodeAnswer"

# App icon: Assets.car for macOS 26, AppIcon.icns for older systems. Needs full Xcode.
# Regenerate the pixel layers with `swift icon/make-icon.swift icon` after editing the art.
if xcrun --find actool >/dev/null 2>&1; then
    ICON_TMP="$(mktemp -d)"
    xcrun actool icon/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon \
        --platform macosx --target-device mac --minimum-deployment-target 14.0 \
        --enable-on-demand-resources NO --output-partial-info-plist "$ICON_TMP/partial.plist" >/dev/null
    rm -rf "$ICON_TMP"
else
    echo "actool not found (needs Xcode); building without an app icon"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>OpenCode Answer</string>
    <key>CFBundleDisplayName</key><string>OpenCode Answer</string>
    <key>CFBundleIdentifier</key><string>dev.preacherxp.opencode-answer</string>
    <key>CFBundleExecutable</key><string>OpenCodeAnswer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: required for notifications and launch at login.
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/OpenCode Answer.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/OpenCode Answer.app"
fi

#!/usr/bin/env bash
set -e

APP_NAME="GitXX"
BUNDLE_DIR="$APP_NAME.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
VERSION="${GITXX_VERSION:-1.0.0}"
BUILD_NUMBER="${GITXX_BUILD:-1}"

echo "🔨 Building $APP_NAME for macOS..."
swift build -c release

echo "📦 Creating application bundle: $BUNDLE_DIR..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR/bin"

# Copy main app executable
cp ".build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"

# Copy CLI executable into bundle
if [ -f "bin/gitxx" ]; then
    cp "bin/gitxx" "$RESOURCES_DIR/bin/gitxx"
    chmod +x "$RESOURCES_DIR/bin/gitxx"
fi

# "GitXX Links" Chrome extension (Settings › General › GitHub links copies it somewhere Chrome can load it from)
rm -rf "$RESOURCES_DIR/ChromeExtension"
cp -R "browser-extension/chrome" "$RESOURCES_DIR/ChromeExtension"
cp "browser-extension/native-host/gitxx-link-host" "$RESOURCES_DIR/gitxx-link-host"
chmod 755 "$RESOURCES_DIR/gitxx-link-host"

# App icon (regenerated from assets/AppIcon-source.png when the source is newer)
if [ -f "assets/AppIcon-source.png" ] && [ "assets/AppIcon-source.png" -nt "assets/AppIcon.icns" ]; then
    swift scripts/make-icon.swift assets/AppIcon-source.png assets/AppIcon.icns
fi
if [ -f "assets/AppIcon.icns" ]; then
    cp "assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Create Info.plist (single window, custom URL scheme, no document types to prevent multiple tabs/windows)
cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.gitxx.macos</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 GitXX. All rights reserved.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>GitXX uses the microphone when you dictate a message to the AI assistant.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>GitXX turns your speech into text for the AI assistant.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.gitxx.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>gitxx</string>
            </array>
        </dict>
    </array></dict>
</plist>
EOF

# Create PkgInfo
echo "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Install symlink to ~/.local/bin/gitxx for instant terminal access (not on CI runners)
if [ -z "$CI" ]; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$(pwd)/bin/gitxx" "$HOME/.local/bin/gitxx"
    echo "🔗 Created CLI symlink at $HOME/.local/bin/gitxx"
fi

echo "✅ Successfully created $BUNDLE_DIR!"
echo "🚀 To launch the app, run: open $BUNDLE_DIR"

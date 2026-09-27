#!/usr/bin/env bash
set -e

APP_NAME="GitXX"
BUNDLE_DIR="$APP_NAME.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

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
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 GitXX. All rights reserved.</string>
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
    </array>
</dict>
</plist>
EOF

# Create PkgInfo
echo "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Install symlink to ~/.local/bin/gitxx for instant terminal access
mkdir -p "$HOME/.local/bin"
ln -sf "$(pwd)/bin/gitxx" "$HOME/.local/bin/gitxx"
echo "🔗 Created CLI symlink at $HOME/.local/bin/gitxx"

echo "✅ Successfully created $BUNDLE_DIR!"
echo "🚀 To launch the app, run: open $BUNDLE_DIR"

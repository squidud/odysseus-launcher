#!/bin/zsh
# Build and install Odysseus Launcher
set -e

APP="/Applications/Odysseus.app"
SCRIPTS_DIR="$(cd "$(dirname "$0")/scripts" && pwd)"
ODYSSEUS_DIR="$HOME/odysseus"

echo "==> Checking dependencies..."
for bin in colima docker git python3; do
    if ! command -v $bin &>/dev/null; then
        echo "Missing: $bin. Install via: brew install $bin"
        exit 1
    fi
done
if ! command -v llama-server &>/dev/null; then
    echo "Missing: llama.cpp. Install via: brew install llama.cpp"
    exit 1
fi

echo "==> Building Odysseus Launcher..."
BUILD_DIR="$(mktemp -d)"
swiftc main.swift -o "$BUILD_DIR/Odysseus"

echo "==> Creating app bundle..."
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BUILD_DIR/Odysseus" "$APP/Contents/MacOS/Odysseus"
chmod +x "$APP/Contents/MacOS/Odysseus"

# Copy launcher scripts into app bundle Resources (used for first-launch install)
for f in llama-server.sh llama-launcher.py json-proxy.py image-server.py register-endpoints.py; do
    cp "$SCRIPTS_DIR/$f" "$APP/Contents/Resources/$f"
done

# Write Info.plist
cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Odysseus</string>
    <key>CFBundleIdentifier</key><string>com.odysseus.launcher</string>
    <key>CFBundleName</key><string>Odysseus</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

# Copy app icon from Odysseus if available
ICON_SRC="$ODYSSEUS_DIR/public/favicon.ico"
if [ -f "$ICON_SRC" ]; then
    # Convert favicon to icns using sips if possible
    TMP_ICON="$(mktemp -d)/icon.png"
    sips -s format png "$ICON_SRC" --out "$TMP_ICON" 2>/dev/null || true
    if [ -f "$TMP_ICON" ]; then
        ICONSET="$(mktemp -d)/AppIcon.iconset"
        mkdir "$ICONSET"
        for size in 16 32 64 128 256 512; do
            sips -z $size $size "$TMP_ICON" --out "$ICONSET/icon_${size}x${size}.png" 2>/dev/null || true
        done
        iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
    fi
fi

# Ad-hoc sign
codesign --force --deep --sign - "$APP" 2>/dev/null || true

rm -rf "$BUILD_DIR"

echo ""
echo "==> Installed: $APP"
echo ""

# Set up scripts in ~/odysseus if it already exists
if [ -d "$ODYSSEUS_DIR" ]; then
    echo "==> Copying launcher scripts to $ODYSSEUS_DIR ..."
    for f in llama-server.sh llama-launcher.py json-proxy.py image-server.py register-endpoints.py; do
        cp "$SCRIPTS_DIR/$f" "$ODYSSEUS_DIR/$f"
    done
    chmod +x "$ODYSSEUS_DIR/llama-server.sh"
    # Copy template config only if none exists
    if [ ! -f "$ODYSSEUS_DIR/llama-config.json" ]; then
        cp "$(dirname "$0")/llama-config.template.json" "$ODYSSEUS_DIR/llama-config.json"
        echo "    Created llama-config.json from template. Edit to match your downloaded models."
    fi
fi

echo "==> Done. Launch Odysseus from Applications or Spotlight."

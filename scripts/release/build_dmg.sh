#!/bin/bash
# Build unsigned DMG for internal distribution
# Usage: ./scripts/release/build_dmg.sh [--skip-core]
# Output: dist/TidyFlow-<version>.dmg

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

# Parse arguments
SKIP_CORE_BUILD=0
for arg in "$@"; do
    case $arg in
        --skip-core) SKIP_CORE_BUILD=1 ;;
    esac
done

echo "[build_dmg] Starting release build..."

# 1. Read version
VERSION_INFO=$("$PROJECT_ROOT/scripts/release/read_version.sh")
SHORT_VERSION=$(echo "$VERSION_INFO" | cut -d' ' -f1)
BUILD_NUMBER=$(echo "$VERSION_INFO" | cut -d' ' -f2)
DMG_NAME="TidyFlow-${SHORT_VERSION}-${BUILD_NUMBER}.dmg"
echo "[build_dmg] Version: $SHORT_VERSION ($BUILD_NUMBER)"

# 2. Clean dist directory
rm -rf dist
mkdir -p dist

# 3. Build Release app with xcodebuild
echo "[build_dmg] Building TidyFlow.app (Release)..."
DERIVED_DATA="$PROJECT_ROOT/dist/DerivedData"

# Set SKIP_CORE_BUILD env var if requested
if [ "$SKIP_CORE_BUILD" = "1" ]; then
    export SKIP_CORE_BUILD=1
    echo "[build_dmg] Skipping core build (--skip-core)"
fi

xcodebuild -project "$PROJECT_ROOT/app/TidyFlow.xcodeproj" \
    -scheme TidyFlow \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    build 2>&1 | grep -E "(Build Succeeded|error:|warning:.*Core|Copied tidyflow)" || true

# Check build result
APP_PATH="$DERIVED_DATA/Build/Products/Release/TidyFlow.app"
if [ ! -d "$APP_PATH" ]; then
    echo "[build_dmg] ERROR: Build failed - TidyFlow.app not found"
    exit 1
fi

# 4. Verify embedded core exists
CORE_PATH="$APP_PATH/Contents/Resources/Core/tidyflow-core"
if [ ! -f "$CORE_PATH" ]; then
    echo "[build_dmg] ERROR: Core binary not found at $CORE_PATH"
    echo "[build_dmg] Hint: Run without --skip-core to build core"
    exit 1
fi
echo "[build_dmg] Core binary verified: $(ls -lh "$CORE_PATH" | awk '{print $5}')"

# 5. Create DMG staging directory
echo "[build_dmg] Creating DMG..."
DMG_ROOT="$PROJECT_ROOT/dist/dmgroot"
mkdir -p "$DMG_ROOT"

# Copy app to staging
cp -R "$APP_PATH" "$DMG_ROOT/"

# Create Applications symlink
ln -s /Applications "$DMG_ROOT/Applications"

# 6. Create DMG
DMG_PATH="$PROJECT_ROOT/dist/$DMG_NAME"
hdiutil create \
    -volname "TidyFlow" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$DMG_PATH" 2>&1 | grep -v "^$" || true

# 7. Cleanup staging
rm -rf "$DMG_ROOT"
rm -rf "$DERIVED_DATA"

# 8. Verify output
if [ ! -f "$DMG_PATH" ]; then
    echo "[build_dmg] ERROR: DMG creation failed"
    exit 1
fi

DMG_SIZE=$(ls -lh "$DMG_PATH" | awk '{print $5}')
echo "[build_dmg] SUCCESS: $DMG_PATH ($DMG_SIZE)"
echo ""
echo "Next steps:"
echo "  1. Double-click DMG to mount"
echo "  2. Drag TidyFlow.app to Applications"
echo "  3. Right-click > Open (first time, Gatekeeper warning)"
echo "  4. Verify: TopToolbar shows 'Running :PORT'"

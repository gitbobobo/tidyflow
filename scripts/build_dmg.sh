#!/bin/bash
# Build DMG for distribution (optionally signed with Developer ID)
# Usage: ./scripts/build_dmg.sh [--skip-core] [--sign] [--identity "Developer ID Application: ..."]
# Output: dist/TidyFlow-<version>.dmg
#
# Signing requires:
#   - Valid "Developer ID Application" certificate in Keychain
#   - Either --identity "..." or SIGN_IDENTITY env var
#
# Examples:
#   ./scripts/build_dmg.sh                    # Unsigned build
#   ./scripts/build_dmg.sh --sign             # Signed (uses SIGN_IDENTITY env)
#   ./scripts/build_dmg.sh --sign --identity "Developer ID Application: Your Name (TEAMID)"

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Parse arguments
SKIP_CORE_BUILD=0
DO_SIGN=0
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

for arg in "$@"; do
    case $arg in
        --skip-core) SKIP_CORE_BUILD=1 ;;
        --sign) DO_SIGN=1 ;;
        --identity=*) SIGN_IDENTITY="${arg#*=}" ;;
    esac
done

# Handle --identity "value" format (next arg)
ARGS=("$@")
for i in "${!ARGS[@]}"; do
    if [[ "${ARGS[$i]}" == "--identity" ]] && [[ $((i+1)) -lt ${#ARGS[@]} ]]; then
        SIGN_IDENTITY="${ARGS[$((i+1))]}"
    fi
done

echo "[build_dmg] Starting release build..."

# 1. Read version
VERSION_INFO=$("$PROJECT_ROOT/scripts/tools/read_version.sh")
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

# 5. Code signing (optional)
if [ "$DO_SIGN" = "1" ]; then
    if [ -z "$SIGN_IDENTITY" ]; then
        echo "[build_dmg] ERROR: --sign requires SIGN_IDENTITY env or --identity argument"
        echo "[build_dmg] List available identities: security find-identity -v -p codesigning"
        exit 1
    fi

    echo "[build_dmg] Signing with: $SIGN_IDENTITY"
    ENTITLEMENTS="$PROJECT_ROOT/app/TidyFlow/TidyFlow.entitlements"

    # 5a. Sign embedded core binary (no entitlements needed)
    echo "[build_dmg] Signing embedded core..."
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$CORE_PATH"

    # 5b. Sign main app bundle (with entitlements)
    echo "[build_dmg] Signing TidyFlow.app..."
    codesign --force --options runtime --timestamp --deep \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$APP_PATH"

    # 5c. Verify signature
    echo "[build_dmg] Verifying signature..."
    if ! codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | head -5; then
        echo "[build_dmg] ERROR: Signature verification failed"
        exit 1
    fi

    # 5d. Gatekeeper assessment (may warn about notarization)
    echo "[build_dmg] Gatekeeper assessment..."
    spctl --assess --type execute --verbose "$APP_PATH" 2>&1 || echo "[build_dmg] Note: spctl may fail until notarized (D5-3)"

    echo "[build_dmg] Signing complete"
fi

# 6. Create DMG staging directory
echo "[build_dmg] Creating DMG..."
DMG_ROOT="$PROJECT_ROOT/dist/dmgroot"
mkdir -p "$DMG_ROOT"

# Copy app to staging
cp -R "$APP_PATH" "$DMG_ROOT/"

# Create Applications symlink
ln -s /Applications "$DMG_ROOT/Applications"

# 7. Create DMG
DMG_PATH="$PROJECT_ROOT/dist/$DMG_NAME"
hdiutil create \
    -volname "TidyFlow" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$DMG_PATH" 2>&1 | grep -v "^$" || true

# 8. Cleanup staging
rm -rf "$DMG_ROOT"
rm -rf "$DERIVED_DATA"

# 9. Verify output
if [ ! -f "$DMG_PATH" ]; then
    echo "[build_dmg] ERROR: DMG creation failed"
    exit 1
fi

DMG_SIZE=$(ls -lh "$DMG_PATH" | awk '{print $5}')
SIGN_STATUS="unsigned"
[ "$DO_SIGN" = "1" ] && SIGN_STATUS="signed"
echo "[build_dmg] SUCCESS: $DMG_PATH ($DMG_SIZE, $SIGN_STATUS)"
echo ""
echo "Next steps:"
if [ "$DO_SIGN" = "1" ]; then
    echo "  1. Double-click DMG to mount"
    echo "  2. Drag TidyFlow.app to Applications"
    echo "  3. App is signed but NOT notarized (D5-3)"
    echo "  4. First run may still show Gatekeeper warning until notarized"
else
    echo "  1. Double-click DMG to mount"
    echo "  2. Drag TidyFlow.app to Applications"
    echo "  3. Right-click > Open (first time, Gatekeeper warning)"
    echo "  4. For signed build: ./scripts/build_dmg.sh --sign"
fi

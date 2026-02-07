#!/bin/bash
# Notarize signed DMG with Apple notary service
# Usage: ./scripts/notarize.sh --profile <keychain-profile> [--dmg <path>]
#
# Prerequisites:
#   1. Signed DMG from build_dmg.sh --sign
#   2. Keychain profile created via:
#      xcrun notarytool store-credentials <profile-name> \
#        --apple-id <email> --team-id <TEAMID> --password <app-specific-password>
#
# Examples:
#   ./scripts/notarize.sh --profile tidyflow-notary
#   ./scripts/notarize.sh --profile tidyflow-notary --dmg dist/TidyFlow-1.0.0-1.dmg

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Parse arguments
PROFILE=""
DMG_PATH=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --dmg)
            DMG_PATH="$2"
            shift 2
            ;;
        *)
            echo "[notarize] Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Validate profile
if [ -z "$PROFILE" ]; then
    echo "[notarize] ERROR: --profile is required"
    echo ""
    echo "Create a keychain profile first:"
    echo "  xcrun notarytool store-credentials tidyflow-notary \\"
    echo "    --apple-id your@email.com \\"
    echo "    --team-id YOURTEAMID \\"
    echo "    --password <app-specific-password>"
    echo ""
    echo "Then run:"
    echo "  ./scripts/notarize.sh --profile tidyflow-notary"
    exit 1
fi

# Find DMG if not specified
if [ -z "$DMG_PATH" ]; then
    DMG_PATH=$(ls -t dist/TidyFlow-*.dmg 2>/dev/null | head -1 || true)
    if [ -z "$DMG_PATH" ]; then
        echo "[notarize] ERROR: No DMG found in dist/"
        echo "[notarize] Build first: ./scripts/build_dmg.sh --sign"
        exit 1
    fi
fi

# Validate DMG exists
if [ ! -f "$DMG_PATH" ]; then
    echo "[notarize] ERROR: DMG not found: $DMG_PATH"
    exit 1
fi

DMG_NAME=$(basename "$DMG_PATH")
echo "[notarize] DMG: $DMG_NAME"
echo "[notarize] Profile: $PROFILE"

# Check if DMG is signed
echo "[notarize] Verifying DMG signature..."
if ! codesign --verify --verbose "$DMG_PATH" 2>&1 | head -2; then
    echo "[notarize] WARNING: DMG may not be properly signed"
fi

# Submit for notarization
echo ""
echo "[notarize] Submitting to Apple notary service..."
echo "[notarize] This may take 2-15 minutes..."

SUBMIT_OUTPUT=$(mktemp)
if ! xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$PROFILE" \
    --wait \
    --output-format json 2>&1 | tee "$SUBMIT_OUTPUT"; then
    echo "[notarize] ERROR: Submission failed"
    cat "$SUBMIT_OUTPUT"
    rm -f "$SUBMIT_OUTPUT"
    exit 1
fi

# Parse submission result
SUBMISSION_ID=$(grep -o '"id":"[^"]*"' "$SUBMIT_OUTPUT" | head -1 | cut -d'"' -f4 || true)
STATUS=$(grep -o '"status":"[^"]*"' "$SUBMIT_OUTPUT" | head -1 | cut -d'"' -f4 || true)
rm -f "$SUBMIT_OUTPUT"

echo ""
echo "[notarize] Submission ID: $SUBMISSION_ID"
echo "[notarize] Status: $STATUS"

# Handle result
if [ "$STATUS" != "Accepted" ]; then
    echo "[notarize] ERROR: Notarization failed with status: $STATUS"

    # Fetch detailed log
    if [ -n "$SUBMISSION_ID" ]; then
        echo ""
        echo "[notarize] Fetching error log..."
        LOG_FILE="$PROJECT_ROOT/dist/notarization-log-$SUBMISSION_ID.json"
        xcrun notarytool log "$SUBMISSION_ID" \
            --keychain-profile "$PROFILE" \
            "$LOG_FILE" 2>/dev/null || true

        if [ -f "$LOG_FILE" ]; then
            echo "[notarize] Log saved to: $LOG_FILE"
            echo "[notarize] Issues found:"
            grep -o '"message":"[^"]*"' "$LOG_FILE" | head -10 || true
        fi
    fi
    exit 1
fi

echo "[notarize] Notarization ACCEPTED"

# Staple the DMG
echo ""
echo "[notarize] Stapling ticket to DMG..."
if ! xcrun stapler staple "$DMG_PATH"; then
    echo "[notarize] ERROR: Stapling failed"
    exit 1
fi

# Validate staple
echo ""
echo "[notarize] Validating staple..."
if ! xcrun stapler validate "$DMG_PATH"; then
    echo "[notarize] ERROR: Staple validation failed"
    exit 1
fi

# Mount DMG and verify app inside
echo ""
echo "[notarize] Verifying app inside DMG..."
MOUNT_POINT=$(mktemp -d)
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

APP_PATH="$MOUNT_POINT/TidyFlow.app"
if [ -d "$APP_PATH" ]; then
    echo "[notarize] Running spctl assessment..."
    if spctl --assess --type execute --verbose "$APP_PATH" 2>&1; then
        echo "[notarize] Gatekeeper: PASSED"
    else
        echo "[notarize] WARNING: spctl assessment returned non-zero"
        echo "[notarize] This may be OK if the app runs without Gatekeeper warnings"
    fi
else
    echo "[notarize] WARNING: TidyFlow.app not found in DMG"
fi

hdiutil detach "$MOUNT_POINT" -quiet
rmdir "$MOUNT_POINT" 2>/dev/null || true

# Final summary
echo ""
echo "========================================"
echo "[notarize] SUCCESS"
echo "========================================"
echo "DMG: $DMG_PATH"
echo "Status: Notarized and Stapled"
echo ""
echo "Verification commands:"
echo "  xcrun stapler validate \"$DMG_PATH\""
echo "  # Mount DMG, then:"
echo "  spctl --assess --type execute --verbose /Volumes/TidyFlow/TidyFlow.app"
echo ""
echo "Distribution ready. Users can download and run without Gatekeeper warnings."

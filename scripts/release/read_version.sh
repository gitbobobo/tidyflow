#!/bin/bash
# Read version from Xcode project settings
# Returns: SHORT_VERSION BUILD_NUMBER (e.g., "1.0 1")

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PBXPROJ="$PROJECT_ROOT/app/TidyFlow.xcodeproj/project.pbxproj"

if [ ! -f "$PBXPROJ" ]; then
    echo "0.1.0 dev" # Fallback
    exit 0
fi

# Extract MARKETING_VERSION (first occurrence in Release config)
SHORT_VERSION=$(grep -m1 "MARKETING_VERSION" "$PBXPROJ" | sed 's/.*= *\([^;]*\);/\1/' | tr -d ' ')

# Extract CURRENT_PROJECT_VERSION (first occurrence in Release config)
BUILD_NUMBER=$(grep -m1 "CURRENT_PROJECT_VERSION" "$PBXPROJ" | sed 's/.*= *\([^;]*\);/\1/' | tr -d ' ')

# Defaults if not found
SHORT_VERSION="${SHORT_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-dev}"

echo "$SHORT_VERSION $BUILD_NUMBER"

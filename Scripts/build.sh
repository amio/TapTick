#!/bin/bash
set -euo pipefail

# Magikeys Build Script
# Usage: ./Scripts/build.sh [debug|release]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEME="Magikeys"
CONFIGURATION="${1:-debug}"
BUILD_DIR="${PROJECT_DIR}/build"

# Capitalize first letter for Xcode
case "$CONFIGURATION" in
    debug)   XCODE_CONFIG="Debug" ;;
    release) XCODE_CONFIG="Release" ;;
    *)       echo "Usage: $0 [debug|release]"; exit 1 ;;
esac

echo "=== Magikeys Build ==="
echo "Configuration: $XCODE_CONFIG"
echo "Build directory: $BUILD_DIR"
echo ""

# Generate Xcode project if needed
if [ ! -f "$PROJECT_DIR/Magikeys.xcodeproj/project.pbxproj" ]; then
    echo "Generating Xcode project..."
    cd "$PROJECT_DIR"
    xcodegen generate
    echo ""
fi

# Build
echo "Building $SCHEME ($XCODE_CONFIG)..."
xcodebuild build \
    -project "$PROJECT_DIR/Magikeys.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$XCODE_CONFIG" \
    -derivedDataPath "$BUILD_DIR" \
    ONLY_ACTIVE_ARCH=YES \
    2>&1 | tail -20

if [ "${PIPESTATUS[0]}" -eq 0 ] 2>/dev/null || true; then
    echo ""
    echo "Build succeeded."

    APP_PATH=$(find "$BUILD_DIR" -name "Magikeys.app" -type d | head -1)
    if [ -n "$APP_PATH" ]; then
        echo "App: $APP_PATH"
    fi
fi

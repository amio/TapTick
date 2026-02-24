#!/bin/bash
set -euo pipefail

# Magikeys Clean Script
# Usage: ./Scripts/clean.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"

echo "=== Magikeys Clean ==="

if [ -d "$BUILD_DIR" ]; then
    rm -rf "$BUILD_DIR"
    echo "Removed: $BUILD_DIR"
fi

if [ -f "$PROJECT_DIR/Magikeys.xcodeproj/project.pbxproj" ]; then
    rm -rf "$PROJECT_DIR/Magikeys.xcodeproj"
    echo "Removed: Magikeys.xcodeproj"
fi

echo "Clean complete."

#!/bin/bash
set -euo pipefail

# Magikeys Setup Script
# Sets up the development environment
# Usage: ./Scripts/setup.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Magikeys Setup ==="

# Check Xcode
echo "Checking Xcode..."
if ! command -v xcodebuild &> /dev/null; then
    echo "ERROR: Xcode command line tools not found."
    echo "Install with: xcode-select --install"
    exit 1
fi
XCODE_VERSION=$(xcodebuild -version | head -1)
echo "  $XCODE_VERSION"

# Check Swift
echo "Checking Swift..."
SWIFT_VERSION=$(swift --version 2>&1 | head -1)
echo "  $SWIFT_VERSION"

# Check xcodegen
echo "Checking xcodegen..."
if ! command -v xcodegen &> /dev/null; then
    echo "  Installing xcodegen..."
    brew install xcodegen
fi
XCODEGEN_VERSION=$(xcodegen --version 2>&1)
echo "  xcodegen $XCODEGEN_VERSION"

# Check swift-format
echo "Checking swift-format..."
if ! command -v swift-format &> /dev/null; then
    echo "  Installing swift-format..."
    brew install swift-format
fi
echo "  $(swift-format --version 2>&1)"

# Generate Xcode project
echo ""
echo "Generating Xcode project..."
cd "$PROJECT_DIR"
xcodegen generate

echo ""
echo "Setup complete! You can now:"
echo "  - Open Magikeys.xcodeproj in Xcode"
echo "  - Run ./Scripts/build.sh to build"
echo "  - Run ./Scripts/test.sh to run tests"
echo "  - Run ./Scripts/format.sh to format code"

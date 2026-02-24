#!/bin/bash
set -euo pipefail

# Magikeys Test Script
# Usage: ./Scripts/test.sh [unit|ui|all]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEME="Magikeys"
BUILD_DIR="${PROJECT_DIR}/build"
TEST_TYPE="${1:-unit}"

echo "=== Magikeys Tests ==="
echo "Type: $TEST_TYPE"
echo ""

# Generate Xcode project if needed
if [ ! -f "$PROJECT_DIR/Magikeys.xcodeproj/project.pbxproj" ]; then
    echo "Generating Xcode project..."
    cd "$PROJECT_DIR"
    xcodegen generate
    echo ""
fi

run_unit_tests() {
    echo "Running unit tests..."
    xcodebuild test \
        -project "$PROJECT_DIR/Magikeys.xcodeproj" \
        -scheme "$SCHEME" \
        -only-testing:MagikeysTests \
        -derivedDataPath "$BUILD_DIR" \
        ONLY_ACTIVE_ARCH=YES \
        2>&1 | grep -E "(Test Case|Test Suite|Tests|error:|warning:|\*\*)" || true

    echo ""
    echo "Unit tests completed."
}

run_ui_tests() {
    echo "Running UI tests..."
    xcodebuild test \
        -project "$PROJECT_DIR/Magikeys.xcodeproj" \
        -scheme "$SCHEME" \
        -only-testing:MagikeysUITests \
        -derivedDataPath "$BUILD_DIR" \
        ONLY_ACTIVE_ARCH=YES \
        2>&1 | grep -E "(Test Case|Test Suite|Tests|error:|warning:|\*\*)" || true

    echo ""
    echo "UI tests completed."
}

case "$TEST_TYPE" in
    unit) run_unit_tests ;;
    ui)   run_ui_tests ;;
    all)
        run_unit_tests
        echo "---"
        run_ui_tests
        ;;
    *)
        echo "Usage: $0 [unit|ui|all]"
        exit 1
        ;;
esac

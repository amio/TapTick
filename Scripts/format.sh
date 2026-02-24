#!/bin/bash
set -euo pipefail

# Magikeys Format Script
# Formats all Swift files using swift-format
# Usage: ./Scripts/format.sh [check]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MODE="${1:-format}"

echo "=== Magikeys Format ==="

# Check if swift-format is installed
if ! command -v swift-format &> /dev/null; then
    echo "swift-format not found. Installing..."
    brew install swift-format
fi

SOURCES=(
    "$PROJECT_DIR/Sources"
    "$PROJECT_DIR/Tests"
)

case "$MODE" in
    check)
        echo "Checking formatting..."
        HAS_ISSUES=0
        for dir in "${SOURCES[@]}"; do
            if [ -d "$dir" ]; then
                if ! swift-format lint --recursive "$dir" 2>&1; then
                    HAS_ISSUES=1
                fi
            fi
        done
        if [ "$HAS_ISSUES" -eq 1 ]; then
            echo ""
            echo "Formatting issues found. Run './Scripts/format.sh' to fix."
            exit 1
        fi
        echo "All files properly formatted."
        ;;
    format)
        echo "Formatting files..."
        for dir in "${SOURCES[@]}"; do
            if [ -d "$dir" ]; then
                swift-format format --in-place --recursive "$dir"
                echo "Formatted: $dir"
            fi
        done
        echo "Done."
        ;;
    *)
        echo "Usage: $0 [check|format]"
        exit 1
        ;;
esac

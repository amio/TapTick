#!/bin/bash
set -euo pipefail

# Magikeys CI Script
# Runs the full CI pipeline: format check, build, test
# Usage: ./Scripts/ci.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo "  Magikeys CI Pipeline"
echo "========================================="
echo ""

# Step 1: Format check
echo "--- Step 1: Format Check ---"
"$SCRIPT_DIR/format.sh" check
echo ""

# Step 2: Build (Release)
echo "--- Step 2: Build (Release) ---"
"$SCRIPT_DIR/build.sh" release
echo ""

# Step 3: Unit Tests
echo "--- Step 3: Unit Tests ---"
"$SCRIPT_DIR/test.sh" unit
echo ""

echo "========================================="
echo "  CI Pipeline Passed"
echo "========================================="

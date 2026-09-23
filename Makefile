# =============================================================================
# TapTick — Makefile
# =============================================================================

SHELL := /bin/bash

PROJECT   := TapTick.xcodeproj
SCHEME    := TapTick
BUILD_DIR := build
DEBUG_APP_NAME := TapTick Dev

# Keychain profile name created via:
#   xcrun notarytool store-credentials "TapTick" --apple-id ... --team-id ... --password ...
# Override on the command line: make dist NOTARIZE_PROFILE=MyOtherProfile
NOTARIZE_PROFILE ?= TapTick

# Detect xcbeautify for prettier xcodebuild output. Preserve both pipeline exit
# codes explicitly because macOS ships GNU Make 3.81, which ignores .SHELLFLAGS.
XCBEAUTIFY := $(shell command -v xcbeautify 2>/dev/null)
PRETTY     := $(if $(XCBEAUTIFY), | xcbeautify; status=("$${PIPESTATUS[@]}"); test "$${status[0]}" -eq 0 -a "$${status[1]}" -eq 0,)
SWIFT_FORMAT := $(shell command -v swift-format 2>/dev/null || xcrun --find swift-format 2>/dev/null)

# Re-export PATH so brew-installed tools are found when invoked via Xcode run scripts
export PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)

.DEFAULT_GOAL := help

.PHONY: help setup gen open \
        build release run \
        test uitest test-all \
        format lint \
        archive export notarize dmg dist \
        clean reset \
        ci \
        version-patch version-minor version-major version-build

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

help: ## Show available targets
	@echo ""
	@echo "  TapTick"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	    | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo ""

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------

setup: ## Install required tools and generate Xcode project
	@echo "→ Checking tools..."
	@command -v xcodegen   >/dev/null || (echo "  Installing xcodegen..."   && brew install xcodegen)
	@command -v swift-format >/dev/null || xcrun --find swift-format >/dev/null 2>&1 || (echo "  Installing swift-format..." && brew install swift-format)
	@command -v xcbeautify >/dev/null || (echo "  Installing xcbeautify..." && brew install xcbeautify)
	@echo "  ✓ xcodegen   $$(xcodegen version)"
	@SWIFT_FORMAT_PATH="$$(command -v swift-format 2>/dev/null || xcrun --find swift-format)"; \
	    echo "  ✓ swift-format $$($$SWIFT_FORMAT_PATH --version 2>&1)"
	@echo "  ✓ xcbeautify $$(xcbeautify --version 2>&1)"
	@echo ""
	@$(MAKE) gen

# -----------------------------------------------------------------------------
# Project generation
# -----------------------------------------------------------------------------

gen: ## Regenerate Xcode project from project.yml (run after editing project.yml)
	@echo "→ Generating Xcode project..."
	xcodegen generate

open: gen ## Regenerate and open project in Xcode
	open $(PROJECT)

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

build: ## Build app — Debug (via xcodebuild)
	@echo "→ Building (Debug)..."
	xcodebuild build \
	    -project $(PROJECT) \
	    -scheme  $(SCHEME) \
	    -configuration Debug \
	    -derivedDataPath $(BUILD_DIR) \
	    ONLY_ACTIVE_ARCH=YES \
	    $(PRETTY)

release: ## Build app — Release (via xcodebuild)
	@echo "→ Building (Release)..."
	xcodebuild build \
	    -project $(PROJECT) \
	    -scheme  $(SCHEME) \
	    -configuration Release \
	    -derivedDataPath $(BUILD_DIR) \
	    $(PRETTY)

run: ## Build (Debug), replace the running instance, and launch the app
	@$(MAKE) --no-print-directory build
	@if pgrep -x "$(DEBUG_APP_NAME)" >/dev/null; then \
	    echo "→ Stopping existing $(DEBUG_APP_NAME) instance..."; \
	    pkill -TERM -x "$(DEBUG_APP_NAME)" || true; \
	    for attempt in {1..50}; do \
	        pgrep -x "$(DEBUG_APP_NAME)" >/dev/null || break; \
	        sleep 0.1; \
	    done; \
	    if pgrep -x "$(DEBUG_APP_NAME)" >/dev/null; then \
	        echo "  ! App did not exit in time; forcing it to stop"; \
	        pkill -KILL -x "$(DEBUG_APP_NAME)"; \
	        for attempt in {1..10}; do \
	            pgrep -x "$(DEBUG_APP_NAME)" >/dev/null || break; \
	            sleep 0.1; \
	        done; \
	    fi; \
	    if pgrep -x "$(DEBUG_APP_NAME)" >/dev/null; then \
	        echo "  ! Could not stop the existing app instance"; \
	        exit 1; \
	    fi; \
	fi
	@echo "→ Launching $(DEBUG_APP_NAME)..."
	@APP_PATH="$(BUILD_DIR)/Build/Products/Debug/$(DEBUG_APP_NAME).app"; \
	if [ -d "$$APP_PATH" ]; then \
	    open "$$APP_PATH"; \
	else \
	    BIN="$$APP_PATH/Contents/MacOS/$(DEBUG_APP_NAME)"; \
	    if [ -x "$$BIN" ]; then \
	        exec "$$BIN"; \
	    else \
	        echo "  ! Could not find app at $$APP_PATH"; exit 1; \
	    fi \
	fi

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

test: ## Run unit tests via xcodebuild
	@echo "→ Running unit tests..."
	xcodebuild test \
	    -project $(PROJECT) \
	    -scheme  $(SCHEME) \
	    -only-testing:TapTickTests \
	    -derivedDataPath $(BUILD_DIR) \
	    ONLY_ACTIVE_ARCH=YES \
	    CODE_SIGNING_ALLOWED=NO \
	    $(PRETTY)

uitest: ## Run UI tests via xcodebuild
	@echo "→ Running UI tests..."
	xcodebuild test \
	    -project $(PROJECT) \
	    -scheme  $(SCHEME) \
	    -only-testing:TapTickUITests \
	    -derivedDataPath $(BUILD_DIR) \
	    ONLY_ACTIVE_ARCH=YES \
	    $(PRETTY)

test-all: test uitest ## Run all tests (unit + UI)

# -----------------------------------------------------------------------------
# Code quality
# -----------------------------------------------------------------------------

format: ## Auto-format all Swift source files with swift-format
	@echo "→ Formatting..."
	@test -n "$(SWIFT_FORMAT)" || (echo "  ! swift-format not found; run 'make setup'"; exit 1)
	$(SWIFT_FORMAT) format --configuration .swift-format --in-place --recursive Sources Tests
	@echo "  ✓ done"

lint: ## Lint Swift source files with swift-format (no writes)
	@echo "→ Linting..."
	@test -n "$(SWIFT_FORMAT)" || (echo "  ! swift-format not found; run 'make setup'"; exit 1)
	$(SWIFT_FORMAT) lint --configuration .swift-format --strict --recursive Sources Tests
	@echo "  ✓ done"

# -----------------------------------------------------------------------------
# Versioning  (simulates npm version patch / minor / major)
#
# Version numbers are stored in project.yml. This workflow updates project.yml,
# regenerates the Xcode project, and commits the changes.
#
# version-patch/minor/major workflow:
#   1. Read MARKETING_VERSION and CURRENT_PROJECT_VERSION from project.yml
#   2. Compute next semver; increment build number
#   3. Write both back into project.yml
#   4. Run `make gen` to update TapTick.xcodeproj
#   5. Commit project.yml, create an annotated git tag vX.Y.Z
#
# version-build workflow:
#   1. Read and increment CURRENT_PROJECT_VERSION only
#   2. Write back into project.yml and run `make gen`
#   3. Commit project.yml
# -----------------------------------------------------------------------------

_read_ver   = $(shell grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')
_read_build = $(shell grep -m1 'CURRENT_PROJECT_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')

# Internal macro — bumps a semver component and zeroes trailing ones, then
# writes project.yml, regenerates, and commits.  Usage: $(call _bump_version,patch|minor|major|build)
define _bump_version
	@set -e; \
	OLD_VER="$(_read_ver)"; \
	OLD_BUILD="$(_read_build)"; \
	MAJOR=$$(echo "$$OLD_VER" | cut -d. -f1); \
	MINOR=$$(echo "$$OLD_VER" | cut -d. -f2); \
	PATCH=$$(echo "$$OLD_VER" | cut -d. -f3); \
	case "$(1)" in \
	  major) MAJOR=$$((MAJOR+1)); MINOR=0; PATCH=0 ;; \
	  minor) MINOR=$$((MINOR+1)); PATCH=0 ;; \
	  patch) PATCH=$$((PATCH+1)) ;; \
	  build) ;; \
	esac; \
	NEW_VER="$$MAJOR.$$MINOR.$$PATCH"; \
	NEW_BUILD=$$((OLD_BUILD+1)); \
	if [ "$(1)" = "build" ]; then \
	  echo "→ Bumping build: $$OLD_BUILD → $$NEW_BUILD (version stays $$OLD_VER)"; \
	  perl -i -pe "s/^(\s+CURRENT_PROJECT_VERSION:\s+)\"[^\"]+\"/\$${1}\"$$NEW_BUILD\"/" project.yml; \
	  $(MAKE) --no-print-directory gen; \
	  git add project.yml; \
	  git commit -m "chore(release): bump build number to $$NEW_BUILD"; \
      git tag -a "v$$OLD_VER+b$$NEW_BUILD" -m "Release v$$OLD_VER build $$NEW_BUILD"; \
	  echo "  ✓ committed build $$NEW_BUILD"; \
	else \
	  echo "→ Bumping version : $$OLD_VER → $$NEW_VER"; \
	  echo "→ Bumping build   : $$OLD_BUILD → $$NEW_BUILD"; \
	  perl -i -pe "s/^(\s+MARKETING_VERSION:\s+)\"[^\"]+\"/\$${1}\"$$NEW_VER\"/" project.yml; \
	  perl -i -pe "s/^(\s+CURRENT_PROJECT_VERSION:\s+)\"[^\"]+\"/\$${1}\"$$NEW_BUILD\"/" project.yml; \
	  $(MAKE) --no-print-directory gen; \
	  git add project.yml; \
	  git commit -m "chore(release): bump version to $$NEW_VER (build $$NEW_BUILD)"; \
	  git tag -a "v$$NEW_VER" -m "Release v$$NEW_VER"; \
	  echo "  ✓ tagged v$$NEW_VER"; \
	fi
endef

version-patch: ## Bump patch version (1.0.0 → 1.0.1), commit and tag
	$(call _bump_version,patch)

version-minor: ## Bump minor version (1.0.0 → 1.1.0), commit and tag
	$(call _bump_version,minor)

version-major: ## Bump major version (1.0.0 → 2.0.0), commit and tag
	$(call _bump_version,major)

version-build: ## Bump build number only, no semver change, commit and tag
	$(call _bump_version,build)

# -----------------------------------------------------------------------------
# Archive / Release
# -----------------------------------------------------------------------------

ARCHIVE_PATH        := $(BUILD_DIR)/$(SCHEME).xcarchive
EXPORT_PATH         := $(BUILD_DIR)/export
EXPORT_OPTIONS_PLIST := Resources/exportOptions.plist

archive: ## Create a Release archive (.xcarchive) signed with Developer ID
	@echo "→ Archiving..."
	xcodebuild archive \
	    -project     $(PROJECT) \
	    -scheme      $(SCHEME) \
	    -configuration Release \
	    -archivePath $(ARCHIVE_PATH) \
	    CODE_SIGN_IDENTITY="Developer ID Application" \
	    CODE_SIGN_STYLE=Manual \
	    PROVISIONING_PROFILE_SPECIFIER="" \
	    $(PRETTY)
	@echo "  ✓ archive: $(ARCHIVE_PATH)"

export: archive ## Export archive as a Developer ID-signed .app ready for notarization
	@echo "→ Exporting..."
	xcodebuild -exportArchive \
	    -archivePath      $(ARCHIVE_PATH) \
	    -exportPath       $(EXPORT_PATH) \
	    -exportOptionsPlist $(EXPORT_OPTIONS_PLIST) \
	    $(PRETTY)
	@echo "  ✓ exported: $(EXPORT_PATH)/$(SCHEME).app"

notarize: ## Submit exported .app to Apple Notary Service and staple the ticket
	@echo "→ Notarizing (profile: $(NOTARIZE_PROFILE))..."
	@# Zip the .app for submission (notarytool accepts .zip, .dmg, or .pkg)
	ditto -c -k --keepParent "$(EXPORT_PATH)/$(SCHEME).app" "$(EXPORT_PATH)/$(SCHEME).zip"
	xcrun notarytool submit "$(EXPORT_PATH)/$(SCHEME).zip" \
	    --keychain-profile "$(NOTARIZE_PROFILE)" \
	    --wait
	@echo "→ Stapling notarization ticket..."
	xcrun stapler staple "$(EXPORT_PATH)/$(SCHEME).app"
	@echo "  ✓ notarized and stapled: $(EXPORT_PATH)/$(SCHEME).app"

dist: export notarize dmg ## Full distribution pipeline: archive → export → notarize → staple → DMG
	@echo "  ✓ Distribution build ready: $(BUILD_DIR)/TapTick.dmg"

dmg: ## Package the notarized .app into a distributable DMG
	@echo "→ Creating DMG..."
	create-dmg \
	    --volname        "TapTick" \
	    --window-pos     200 120 \
	    --window-size    660 400 \
	    --icon-size      128 \
	    --icon           "TapTick.app" 180 170 \
	    --hide-extension "TapTick.app" \
	    --app-drop-link  480 170 \
	    "$(BUILD_DIR)/TapTick.dmg" \
	    "$(EXPORT_PATH)/$(SCHEME).app"
	@echo "  ✓ DMG: $(BUILD_DIR)/TapTick.dmg"

# -----------------------------------------------------------------------------
# Clean
# -----------------------------------------------------------------------------

clean: ## Remove build artifacts (keeps .xcodeproj)
	@echo "→ Cleaning build artifacts..."
	rm -rf $(BUILD_DIR)
	swift package clean
	@echo "  ✓ done"

reset: clean ## Full reset — also removes .xcodeproj (run 'make gen' afterwards)
	@echo "→ Removing generated project..."
	rm -rf $(PROJECT)
	@echo "  ✓ done. Run 'make gen' to regenerate."

# -----------------------------------------------------------------------------
# CI
# -----------------------------------------------------------------------------

ci: ## Full CI pipeline: lint → unit tests → release build
	@echo "========================================="
	@echo "  TapTick CI Pipeline"
	@echo "========================================="
	@echo ""
	@echo "--- lint ---"
	@$(MAKE) --no-print-directory lint
	@echo ""
	@echo "--- unit tests ---"
	@$(MAKE) --no-print-directory test
	@echo ""
	@echo "--- release build ---"
	@$(MAKE) --no-print-directory release
	@echo ""
	@echo "========================================="
	@echo "  ✓ CI passed"
	@echo "========================================="

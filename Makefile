# Faded — build orchestration.
#
#   make            → build the app (Release), result in build/Faded.app
#   make install    → copy Faded.app to /Applications and open it
#   make uninstall  → remove app + prefs (+ the old driver, if one is installed)
#   make clean

SHELL := /bin/bash
ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
APP_DIR := $(ROOT)/app
OUT     := $(ROOT)/build
CONFIG  ?= Release
# Code signing identity.
#
# Defaults to ad-hoc ("-"), which builds and runs fine. For day-to-day use set
# a real identity instead — an ad-hoc signature changes on every build, so
# macOS treats each rebuild as a different app and resets its permissions and
# its login-item registration. Either export it:
#
#     make CODESIGN_ID="Apple Development: you@example.com (TEAMID)"
#
# or drop that line into an untracked local.mk, which is included below.
-include $(ROOT)/local.mk
CODESIGN_ID ?= -

.PHONY: all app bridge-helper install uninstall clean

all: app

# The native-messaging relay Chrome spawns to reach the app. Single Swift
# file, no project — built straight into the bundle's Helpers directory, after
# which the bundle must be re-signed (adding a file breaks the seal).
bridge-helper:
	@mkdir -p $(ROOT)/bridge/build
	swiftc -O -o $(ROOT)/bridge/build/faded-native-host $(ROOT)/bridge/faded-native-host.swift
	codesign --force --timestamp=none -s "$(CODESIGN_ID)" $(ROOT)/bridge/build/faded-native-host

app: bridge-helper
	cd $(APP_DIR) && xcodegen generate
	cd $(APP_DIR) && xcodebuild -project Faded.xcodeproj -scheme Faded -configuration $(CONFIG) \
	    -derivedDataPath build CODE_SIGN_IDENTITY="$(CODESIGN_ID)" build | grep -E "error|warning: .*Sources/Faded|BUILD" || true
	@test -d $(APP_DIR)/build/Build/Products/$(CONFIG)/Faded.app || (echo "build failed" && exit 1)
	@mkdir -p $(OUT)
	@rm -rf $(OUT)/Faded.app
	@cp -R $(APP_DIR)/build/Build/Products/$(CONFIG)/Faded.app $(OUT)/
	@mkdir -p $(OUT)/Faded.app/Contents/Helpers
	cp $(ROOT)/bridge/build/faded-native-host $(OUT)/Faded.app/Contents/Helpers/
	codesign --force --timestamp=none -s "$(CODESIGN_ID)" $(OUT)/Faded.app
	@echo "app ok: $(OUT)/Faded.app"

install: app
	-osascript -e 'tell application "Faded" to quit' 2>/dev/null
	@sleep 1
	@rm -rf /Applications/Faded.app
	cp -R $(OUT)/Faded.app /Applications/
	open /Applications/Faded.app
	@echo "Faded is running in the menu bar."

uninstall:
	-osascript -e 'tell application "Faded" to quit' 2>/dev/null
	-rm -rf /Applications/Faded.app
	-defaults delete com.andri.faded 2>/dev/null
	-rm -rf "$$HOME/Library/Application Support/Faded"
	@if [ -d /Library/Audio/Plug-Ins/HAL/FadedDriver.driver ]; then sudo $(ROOT)/scripts/uninstall-driver.sh; fi

clean:
	rm -rf $(APP_DIR)/build $(APP_DIR)/Faded.xcodeproj $(ROOT)/bridge/build $(OUT)

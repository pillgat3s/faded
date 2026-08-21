# Faded — build orchestration.
#
#   make            → driver + app (Release), result in build/Faded.app
#   make driver     → build the HAL plug-in only (driver/build/FadedDriver.driver)
#   make app        → xcodegen + xcodebuild the app (embeds the driver)
#   make install    → copy Faded.app to /Applications and open it (the app
#                     installs the driver itself with an admin prompt)
#   make install-driver / uninstall-driver → do the driver part from the shell
#   make uninstall  → remove app + driver + prefs (asks for password)
#   make check-protocol → make sure the C header and the Swift mirror agree
#   make clean

SHELL := /bin/bash
ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
DRIVER_DIR := $(ROOT)/driver
APP_DIR    := $(ROOT)/app
OUT        := $(ROOT)/build
CONFIG     ?= Release
# Code signing identity for both the driver and the app.
#
# Defaults to ad-hoc ("-"), which builds and runs fine. For day-to-day use set
# a real identity instead — an ad-hoc signature changes on every build, so
# macOS treats each rebuild as a different app and resets its microphone
# permission and its login-item registration. Either export it:
#
#     make CODESIGN_ID="Apple Development: you@example.com (TEAMID)"
#
# or drop that line into an untracked local.mk, which is included below.
-include $(ROOT)/local.mk
CODESIGN_ID ?= -

.PHONY: all driver app install install-driver uninstall-driver uninstall check-protocol clean

all: driver app

driver:
	cmake -S $(DRIVER_DIR) -B $(DRIVER_DIR)/build -DCMAKE_BUILD_TYPE=Release -DCODESIGN_ID="$(CODESIGN_ID)" -Wno-dev
	cmake --build $(DRIVER_DIR)/build -j8
	@codesign --verify --strict $(DRIVER_DIR)/build/FadedDriver.driver && echo "driver ok: $(DRIVER_DIR)/build/FadedDriver.driver"

app: driver check-protocol
	cd $(APP_DIR) && xcodegen generate
	cd $(APP_DIR) && xcodebuild -project Faded.xcodeproj -scheme Faded -configuration $(CONFIG) \
	    -derivedDataPath build CODE_SIGN_IDENTITY="$(CODESIGN_ID)" build | grep -E "error|warning: .*Sources/Faded|BUILD" || true
	@mkdir -p $(OUT)
	@rm -rf $(OUT)/Faded.app
	@cp -R $(APP_DIR)/build/Build/Products/$(CONFIG)/Faded.app $(OUT)/
	@echo "app ok: $(OUT)/Faded.app"

install: app
	@rm -rf /Applications/Faded.app
	cp -R $(OUT)/Faded.app /Applications/
	open /Applications/Faded.app
	@echo "Faded is running in the menu bar. Click it → Install Driver…"

install-driver: driver
	sudo $(ROOT)/scripts/install-driver.sh $(DRIVER_DIR)/build/FadedDriver.driver

uninstall-driver:
	sudo $(ROOT)/scripts/uninstall-driver.sh

uninstall:
	-osascript -e 'tell application "Faded" to quit' 2>/dev/null
	-rm -rf /Applications/Faded.app
	-defaults delete com.andri.faded 2>/dev/null
	sudo $(ROOT)/scripts/uninstall-driver.sh

check-protocol:
	@$(ROOT)/scripts/check-protocol.sh

clean:
	rm -rf $(DRIVER_DIR)/build $(APP_DIR)/build $(APP_DIR)/Faded.xcodeproj $(OUT)

# Fader — build orchestration.
#
#   make            → driver + app (Release), result in build/Fader.app
#   make driver     → build the HAL plug-in only (driver/build/FaderDriver.driver)
#   make app        → xcodegen + xcodebuild the app (embeds the driver)
#   make install    → copy Fader.app to /Applications and open it (the app
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
# Same identity the app uses (see app/project.yml). Override with
# CODESIGN_ID=- for ad-hoc.
CODESIGN_ID ?= Apple Development: thomannandri@gmail.com (R6QBGGCUGC)

.PHONY: all driver app install install-driver uninstall-driver uninstall check-protocol clean

all: driver app

driver:
	cmake -S $(DRIVER_DIR) -B $(DRIVER_DIR)/build -DCMAKE_BUILD_TYPE=Release -DCODESIGN_ID="$(CODESIGN_ID)" -Wno-dev
	cmake --build $(DRIVER_DIR)/build -j8
	@codesign --verify --strict $(DRIVER_DIR)/build/FaderDriver.driver && echo "driver ok: $(DRIVER_DIR)/build/FaderDriver.driver"

app: driver check-protocol
	cd $(APP_DIR) && xcodegen generate
	cd $(APP_DIR) && xcodebuild -project Fader.xcodeproj -scheme Fader -configuration $(CONFIG) \
	    -derivedDataPath build build | grep -E "error|warning: .*Sources/Fader|BUILD" || true
	@mkdir -p $(OUT)
	@rm -rf $(OUT)/Fader.app
	@cp -R $(APP_DIR)/build/Build/Products/$(CONFIG)/Fader.app $(OUT)/
	@echo "app ok: $(OUT)/Fader.app"

install: app
	@rm -rf /Applications/Fader.app
	cp -R $(OUT)/Fader.app /Applications/
	open /Applications/Fader.app
	@echo "Fader is running in the menu bar. Click it → Install Driver…"

install-driver: driver
	sudo $(ROOT)/scripts/install-driver.sh $(DRIVER_DIR)/build/FaderDriver.driver

uninstall-driver:
	sudo $(ROOT)/scripts/uninstall-driver.sh

uninstall:
	-osascript -e 'tell application "Fader" to quit' 2>/dev/null
	-rm -rf /Applications/Fader.app
	-defaults delete com.andri.fader 2>/dev/null
	sudo $(ROOT)/scripts/uninstall-driver.sh

check-protocol:
	@$(ROOT)/scripts/check-protocol.sh

clean:
	rm -rf $(DRIVER_DIR)/build $(APP_DIR)/build $(APP_DIR)/Fader.xcodeproj $(OUT)

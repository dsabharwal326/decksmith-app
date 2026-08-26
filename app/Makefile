APP_DEBUG   := build/macos/Build/Products/Debug/decksmith_app.app
APP_RELEASE := build/macos/Build/Products/Release/decksmith_app.app
INSTALL_DIR := /Applications

.PHONY: build release install run clean

# Debug build + install to /Applications
build:
	flutter build macos --debug
	@rm -rf "$(INSTALL_DIR)/decksmith_app.app"
	@cp -R "$(APP_DEBUG)" "$(INSTALL_DIR)/decksmith_app.app"
	@echo "Installed → $(INSTALL_DIR)/decksmith_app.app"

# Release build + install to /Applications
release:
	flutter build macos --release
	@rm -rf "$(INSTALL_DIR)/decksmith_app.app"
	@cp -R "$(APP_RELEASE)" "$(INSTALL_DIR)/decksmith_app.app"
	@echo "Installed → $(INSTALL_DIR)/decksmith_app.app"

# Install whatever was last built without rebuilding
install:
	@if [ -d "$(APP_DEBUG)" ]; then \
		rm -rf "$(INSTALL_DIR)/decksmith_app.app"; \
		cp -R "$(APP_DEBUG)" "$(INSTALL_DIR)/decksmith_app.app"; \
		echo "Installed debug build → $(INSTALL_DIR)/decksmith_app.app"; \
	else \
		echo "No build found — run 'make build' first"; exit 1; \
	fi

run: build
	@pkill -x decksmith_app 2>/dev/null || true
	@sleep 0.3
	open "$(INSTALL_DIR)/decksmith_app.app"

clean:
	flutter clean

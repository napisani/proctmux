
# Variables
APP_NAME=proctmux
BINARY_NAME=$(APP_NAME)
VERSION ?=
BUILD_VERSION ?= $(if $(VERSION),$(patsubst v%,%,$(VERSION)),1.0.0-dev)
BUILD_DIR=bin
ZIG ?= zig
AGENT_TUI ?= agent-tui
PYTHON ?= python3
PYTEST_ARGS ?=
BUILD_OUT_DIR=zig-out
BUILD_CACHE_DIR ?= .zig-cache/global
E2E_RUN ?=
platform_flags = -Dtarget=$(1) $(if $(findstring macos,$(1)),--sysroot $(MACOS_SDK),)
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_S),Darwin)
NATIVE_TARGET ?= $(if $(filter arm64 aarch64,$(UNAME_M)),aarch64-macos,x86_64-macos)
MACOS_SDK ?= $(shell xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)
else ifeq ($(UNAME_S),Linux)
NATIVE_TARGET ?= $(if $(filter arm64 aarch64,$(UNAME_M)),aarch64-linux-gnu,x86_64-linux-gnu)
endif
BUILD_FLAGS ?= --global-cache-dir $(BUILD_CACHE_DIR) $(call platform_flags,$(NATIVE_TARGET)) -Dversion=$(BUILD_VERSION)
TEST_CMD=$(ZIG) build test $(BUILD_FLAGS)
BUILD_CMD=$(ZIG) build $(BUILD_FLAGS)
# Run the app
.PHONY: run
run: build
	@echo "Running $(APP_NAME)..."
	./$(BUILD_DIR)/$(BINARY_NAME)

# Build the binary
.PHONY: build
build:
	@echo "Building $(APP_NAME)..."
	@mkdir -p $(BUILD_DIR)
	$(BUILD_CMD)
	@cp $(BUILD_OUT_DIR)/bin/$(BINARY_NAME) $(BUILD_DIR)/$(BINARY_NAME)

.PHONY: test
test:
	@echo "Running unit tests..."
	$(TEST_CMD)

.PHONY: fmt
fmt:
	@echo "Formatting files..."
	$(ZIG) fmt build.zig src

# Build for all supported Unix platforms
.PHONY: build-all
build-all:
	@echo "Building release artifacts for all Unix platforms..."
	$(MAKE) build-release-artifact TARGET=x86_64-linux-gnu ARTIFACT_NAME=$(BINARY_NAME)-linux-amd64
	$(MAKE) build-release-artifact TARGET=aarch64-linux-gnu ARTIFACT_NAME=$(BINARY_NAME)-linux-arm64
	$(MAKE) build-release-artifact TARGET=x86_64-macos ARTIFACT_NAME=$(BINARY_NAME)-darwin-amd64
	$(MAKE) build-release-artifact TARGET=aarch64-macos ARTIFACT_NAME=$(BINARY_NAME)-darwin-arm64
	@echo "Built binaries:"
	@ls -lh $(BUILD_DIR)/$(BINARY_NAME)-*

.PHONY: build-release-artifact
build-release-artifact:
	@if [ -z "$(TARGET)" ] || [ -z "$(ARTIFACT_NAME)" ]; then \
		echo "Usage: make build-release-artifact TARGET=<target> ARTIFACT_NAME=<output-name>" >&2; \
		exit 2; \
	fi
	@echo "Building release artifact $(ARTIFACT_NAME) for $(TARGET)..."
	@mkdir -p $(BUILD_DIR)
	$(ZIG) build --global-cache-dir $(BUILD_CACHE_DIR) $(call platform_flags,$(TARGET)) -Doptimize=ReleaseFast -Dversion=$(BUILD_VERSION)
	@cp $(BUILD_OUT_DIR)/bin/$(BINARY_NAME) $(BUILD_DIR)/$(ARTIFACT_NAME)


# Clean build artifacts
.PHONY: clean
clean:
	@echo "Cleaning up..."
	rm -rf $(BUILD_DIR) $(BUILD_OUT_DIR) .zig-cache

# Create a distribution archive
.PHONY: dist
dist: build
	@echo "Creating distribution archive..."
	mkdir -p release
	tar -czf release/$(BINARY_NAME)-$(if $(VERSION),$(VERSION),dev).tar.gz -C $(BUILD_DIR) $(BINARY_NAME)

.PHONY: inspect
inspect:
	@echo "Inspecting the application..."
	@npx   npx @modelcontextprotocol/inspector  ./bin/$(BINARY_NAME) 

.PHONY: test-e2e
test-e2e: build
	@echo "Running agent-tui end-to-end tests..."
	AGENT_TUI="$(AGENT_TUI)" PROCTMUX_E2E_BIN="$(CURDIR)/$(BUILD_OUT_DIR)/bin/$(BINARY_NAME)" E2E_RUN="$(E2E_RUN)" $(PYTHON) -m pytest -q -s tests/e2e $(PYTEST_ARGS)

.PHONY: test-all
test-all: test test-e2e

.PHONY: tmux-list-panes
tmux-list-panes:
	@echo "Listing tmux panes..."
	@tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}'	

.PHONY: tmux-current-pane
tmux-current-pane:
	@echo "Listing current tmux pane..."
	@tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}'

# Run in tmux split - client in current pane, primary to the right
.PHONY: tmux-run
tmux-run: build
	@echo "Starting proctmux in tmux split..."
	@tmux split-window -h "./bin/$(BINARY_NAME)"
	@./bin/$(BINARY_NAME) --client

# Check if working tree is dirty (used by release targets)
.PHONY: git-dirty
git-dirty:
	@git status --porcelain

# Create a release: run tests, tag, and push (triggers GitHub Actions release workflow)
# Usage: make release-create VERSION=vX.Y.Z
.PHONY: release-create
release-create:
	@set -euo pipefail; \
	if [ -z "$(VERSION)" ]; then \
		echo "Usage: make release-create VERSION=vX.Y.Z" >&2; exit 1; \
	fi; \
	TAG="$(VERSION)"; \
	if ! echo "$$TAG" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then \
		echo "Error: VERSION must be in the format vX.Y.Z (e.g., v1.0.0)" >&2; exit 1; \
	fi; \
	if git rev-parse "$$TAG" >/dev/null 2>&1; then \
		echo "Error: Tag $$TAG already exists. Bump the version before releasing." >&2; exit 1; \
	fi; \
	if [ -n "$$($(MAKE) --silent git-dirty)" ]; then \
		echo "Error: Working tree is dirty. Commit or stash changes before releasing." >&2; exit 1; \
	fi; \
	echo "Preparing release $$TAG"; \
	echo ""; \
	echo "Running release verification..."; \
	$(MAKE) test-all; \
	echo ""; \
	echo "Tagging $$TAG"; \
	git tag -a "$$TAG" -m "Release $$TAG"; \
	git push origin "$$TAG"; \
	echo ""; \
	echo "Release $$TAG created and pushed!"; \
	echo "GitHub Actions will now build release artifacts."; \
	echo "Once the release is ready, run: make release-publish VERSION=$$TAG"

# Publish a release: wait for GitHub Actions, then update the Homebrew formula
# Usage: make release-publish VERSION=vX.Y.Z
.PHONY: release-publish
release-publish:
	@set -euo pipefail; \
	if [ -z "$(VERSION)" ]; then \
		echo "Usage: make release-publish VERSION=vX.Y.Z" >&2; exit 1; \
	fi; \
	TAG="$(VERSION)"; \
	if ! git rev-parse "$$TAG" >/dev/null 2>&1; then \
		echo "Error: Tag $$TAG does not exist. Run 'make release-create VERSION=$$TAG' first." >&2; exit 1; \
	fi; \
	echo "Updating Homebrew formula for $$TAG..."; \
	echo "(Make sure the GitHub Actions release workflow has completed first)"; \
	echo ""; \
	$(MAKE) update-brew VERSION=$$TAG; \
	echo ""; \
	echo "Committing formula update..."; \
	git add Formula/proctmux.rb; \
	git commit -m "brew: update formula to $$TAG"; \
	echo ""; \
	echo "Push this commit to main so 'brew tap' picks it up:"; \
	echo "  git push origin main"

# Full release workflow: create tag + publish (with pause for CI)
# Usage: make release VERSION=vX.Y.Z
.PHONY: release
release:
	@set -euo pipefail; \
	if [ -z "$(VERSION)" ]; then \
		echo "Usage: make release VERSION=vX.Y.Z" >&2; exit 1; \
	fi; \
	$(MAKE) release-create VERSION=$(VERSION); \
	echo ""; \
	echo "======================================================"; \
	echo "Waiting for GitHub Actions to build release artifacts..."; \
	echo "This typically takes 2-3 minutes."; \
	echo "Check: https://github.com/napisani/proctmux/actions"; \
	echo "======================================================"; \
	echo ""; \
	read -p "Press Enter when the release workflow has completed..." _; \
	$(MAKE) release-publish VERSION=$(VERSION)

# Update Homebrew formula for a specific version
.PHONY: update-brew
update-brew:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make update-brew VERSION=vX.Y.Z" >&2; exit 1; fi
	scripts/update-brew.sh $(VERSION)

# Update Homebrew formula for the latest git tag
.PHONY: update-brew-latest
update-brew-latest:
	@set -euo pipefail; \
	LATEST_TAG=$$(git tag --sort=-v:refname | head -n1); \
	if [ -z "$$LATEST_TAG" ]; then \
		echo "No git tags found." >&2; exit 1; \
	fi; \
	echo "Updating Homebrew formula for $$LATEST_TAG"; \
	$(MAKE) update-brew VERSION=$$LATEST_TAG

# Help command
.PHONY: help
help:
	@echo "Makefile commands:"
	@echo "  make build      - Build the application for current platform"
	@echo "  make build-release-artifact TARGET=<target> ARTIFACT_NAME=<name> - Build one release artifact"
	@echo "  make build-all  - Build for all supported Unix platforms (Linux, macOS)"
	@echo "  make run        - Build and run the application"
	@echo "  make clean      - Clean up build artifacts"
	@echo "  make dist       - Create a distribution archive"
	@echo "  make inspect    - Inspect the application with Model Context Protocol"
	@echo "  make test       - Run unit tests"
	@echo "  make test-e2e   - Run agent-tui e2e tests"
	@echo "  make test-all   - Run unit tests and agent-tui e2e tests"
	@echo "  make fmt        - Format source files"
	@echo "  make release-create VERSION=vX.Y.Z - Create a release (test, tag, push)"
	@echo "  make release-publish VERSION=vX.Y.Z - Update Homebrew formula after release"
	@echo "  make release VERSION=vX.Y.Z - Full release workflow (create + publish)"
	@echo "  make update-brew VERSION=vX.Y.Z - Update Homebrew formula for a specific version"
	@echo "  make update-brew-latest - Update Homebrew formula for the latest git tag"
	@echo "  make help       - Show this help message"

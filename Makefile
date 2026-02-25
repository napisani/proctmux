
# Variables
APP_NAME=proctmux
BINARY_NAME=$(APP_NAME)
VERSION=0.1.0
BUILD_DIR=bin
SRC_DIR=cmd/$(APP_NAME)
INTERNAL_DIR=internal
# Run the app
PHONY: run 
run: 
	@echo "Running the application..."
	go run ./$(SRC_DIR)

# Build the binary
.PHONY: build
build:
	@echo "Building the application..."
	go build -o $(BUILD_DIR)/$(BINARY_NAME) ./$(SRC_DIR)

# Build for all supported Unix platforms
.PHONY: build-all
build-all:
	@echo "Building for all Unix platforms..."
	@mkdir -p $(BUILD_DIR)
	GOOS=linux GOARCH=amd64 go build -o $(BUILD_DIR)/$(BINARY_NAME)-linux-amd64 ./$(SRC_DIR)
	GOOS=linux GOARCH=arm64 go build -o $(BUILD_DIR)/$(BINARY_NAME)-linux-arm64 ./$(SRC_DIR)
	GOOS=darwin GOARCH=amd64 go build -o $(BUILD_DIR)/$(BINARY_NAME)-darwin-amd64 ./$(SRC_DIR)
	GOOS=darwin GOARCH=arm64 go build -o $(BUILD_DIR)/$(BINARY_NAME)-darwin-arm64 ./$(SRC_DIR)
	@echo "Built binaries:"
	@ls -lh $(BUILD_DIR)/$(BINARY_NAME)-*


# Clean build artifacts
.PHONY: clean
clean:
	@echo "Cleaning up..."
	rm -rf $(BUILD_DIR)

# Create a distribution archive
.PHONY: dist
dist: build
	@echo "Creating distribution archive..."
	mkdir -p release
	tar -czf release/$(BINARY_NAME)-$(VERSION).tar.gz -C $(BUILD_DIR) $(BINARY_NAME)

# Watch for changes and rebuild
.PHONY: watch
watch:
	@echo "Watching for changes..."
	@nodemon  --exec "make build ; exit 0" --watch $(SRC_DIR) --watch $(INTERNAL_DIR) --ext go  --signal SIGINT  

.PHONY: inspect
inspect:
	@echo "Inspecting the application..."
	@npx   npx @modelcontextprotocol/inspector  ./bin/$(BINARY_NAME) 

.PHONY: tidy 
tidy:
	@echo "Tidying up dependencies..."
	go mod tidy 

# Update the vendorHash in flake.nix to match current dependencies
# This is needed when go.mod/go.sum change and Nix builds fail with hash mismatch
# Usage: make update-vendor-hash
.PHONY: update-vendor-hash
update-vendor-hash:
	@echo "Updating vendorHash in flake.nix..."
	@echo "Step 1: Setting vendorHash to pkgs.lib.fakeHash..."
	@sed -i.bak 's/vendorHash = ".*";/vendorHash = pkgs.lib.fakeHash;/' flake.nix
	@echo "Step 2: Building flake to get correct hash (this will fail, that's expected)..."
	@CORRECT_HASH=$$(nix build .#default 2>&1 | grep -E '^\s+got:\s+' | sed 's/.*got:[[:space:]]*//'); \
	if [ -z "$$CORRECT_HASH" ]; then \
		echo "Error: Could not extract hash from nix build output"; \
		echo "Restoring original flake.nix..."; \
		mv flake.nix.bak flake.nix; \
		exit 1; \
	fi; \
	echo "Step 3: Updating flake.nix with correct hash: $$CORRECT_HASH"; \
	sed -i.bak2 "s|vendorHash = pkgs.lib.fakeHash;|vendorHash = \"$$CORRECT_HASH\";|" flake.nix; \
	rm -f flake.nix.bak flake.nix.bak2
	@echo "Step 4: Verifying the build works..."
	@nix build .#default && echo "✓ vendorHash updated successfully!" || (echo "✗ Build failed, please check flake.nix"; exit 1)

# Install git hooks from .githooks/ directory
.PHONY: install-hooks
install-hooks:
	@echo "Installing git hooks..."
	@if [ ! -d .githooks ]; then \
		echo "Error: .githooks directory not found"; \
		exit 1; \
	fi
	@for hook in .githooks/*; do \
		if [ -f "$$hook" ] && [ "$$(basename "$$hook")" != "README.md" ]; then \
			hook_name=$$(basename "$$hook"); \
			echo "Installing $$hook_name..."; \
			cp "$$hook" .git/hooks/; \
			chmod +x .git/hooks/$$hook_name; \
		fi; \
	done
	@echo "✓ Git hooks installed successfully!"
	@echo ""
	@echo "Installed hooks:"
	@ls -1 .githooks/ | grep -v README.md


.PHONY: test
test:
	@echo "Running tests..."
	go test ./... -v

.PHONY: test-e2e
test-e2e:
	@echo "Running integration (e2e) tests..."
	go test -tags=integration ./tests/e2e -v

.PHONY: test-race
test-race:
	@echo "Running race detector tests..."
	go test -race ./... -v


.PHONY: watch-test 
watch-test:
	@echo "Watching for test changes..."
	@nodemon --exec "make test ; exit 0" --watch $(SRC_DIR) --watch $(INTERNAL_DIR) --ext go --signal SIGINT


.PHONEY tmux-list-panes:
	@echo "Listing tmux panes..."
	@tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}'	

.PHONY tmux-current-pane:
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
		echo "Error: VERSION must be in the format vX.Y.Z (e.g., v0.2.0)" >&2; exit 1; \
	fi; \
	if git rev-parse "$$TAG" >/dev/null 2>&1; then \
		echo "Error: Tag $$TAG already exists. Bump the version before releasing." >&2; exit 1; \
	fi; \
	if [ -n "$$($(MAKE) --silent git-dirty)" ]; then \
		echo "Error: Working tree is dirty. Commit or stash changes before releasing." >&2; exit 1; \
	fi; \
	echo "Preparing release $$TAG"; \
	echo ""; \
	echo "Running tests..."; \
	$(MAKE) test; \
	echo ""; \
	echo "Running vet..."; \
	go vet ./...; \
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
	@echo "  make build-all  - Build for all supported Unix platforms (Linux, macOS)"
	@echo "  make run        - Build and run the application"
	@echo "  make clean      - Clean up build artifacts"
	@echo "  make dist       - Create a distribution archive"
	@echo "  make watch      - Watch for changes and rebuild"
	@echo "  make inspect    - Inspect the application with Model Context Protocol"
	@echo "  make tidy       - Tidy up dependencies"
	@echo "  make test       - Run tests"
	@echo "  make test-e2e   - Run integration (e2e) tests"
	@echo "  make test-race  - Run tests with race detector"
	@echo "  make update-vendor-hash - Update vendorHash in flake.nix for Nix builds"
	@echo "  make install-hooks - Install git hooks from .githooks/ directory"
	@echo "  make release-create VERSION=vX.Y.Z - Create a release (test, tag, push)"
	@echo "  make release-publish VERSION=vX.Y.Z - Update Homebrew formula after release"
	@echo "  make release VERSION=vX.Y.Z - Full release workflow (create + publish)"
	@echo "  make update-brew VERSION=vX.Y.Z - Update Homebrew formula for a specific version"
	@echo "  make update-brew-latest - Update Homebrew formula for the latest git tag"
	@echo "  make help       - Show this help message"





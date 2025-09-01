
# Variables
APP_NAME=proctmux
BINARY_NAME=$(APP_NAME)
VERSION=0.1.0
BUILD_DIR=bin
SRC_DIR=cmd/$(APP_NAME)
INTERNAL_DIR=internal
# Run the app
PHONY: run 
run: 
	@echo "Running the application..."
	go run $(SRC_DIR)/main.go

# Build the binary
.PHONY: build
build:
	@echo "Building the application..."
	go build -o $(BUILD_DIR)/$(BINARY_NAME) $(SRC_DIR)/main.go

# Run the application
.PHONY: run
run: build
	@echo "Running the application..."
	./$(BUILD_DIR)/$(BINARY_NAME)

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

.PHONY: test
test:
	@echo "Running tests..."
	go test ./... -v

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

# Help command
.PHONY: help
help:
	@echo "Makefile commands:"
	@echo "  make build   - Build the application"
	@echo "  make run     - Build and run the application"
	@echo "  make clean   - Clean up build artifacts"
	@echo "  make dist    - Create a distribution archive"
	@echo "  make watch   - Watch for changes and rebuild"
	@echo "  make inspect - Inspect the application with Model Context Protocol"
	@echo "  make tidy - Tidy up dependencies"
	@echo "  make help    - Show this help message"





.PHONY: build build-quota install install-local clean test help

# Binary names
USAGE_BINARY = claude-usage
USAGE_SOURCE = claude-usage.swift
QUOTA_BINARY = claude-quota
QUOTA_SOURCE = claude-quota.swift
INSTALL_PATH = /usr/local/bin

# Build both binaries
build: build-usage build-quota

# Build usage tracker
build-usage:
	@echo "Compiling $(USAGE_BINARY)..."
	swiftc -O -o $(USAGE_BINARY) $(USAGE_SOURCE)
	@echo "Built $(USAGE_BINARY) successfully"

# Build quota tracker
build-quota:
	@echo "Compiling $(QUOTA_BINARY)..."
	swiftc -O -o $(QUOTA_BINARY) $(QUOTA_SOURCE)
	@echo "Built $(QUOTA_BINARY) successfully"

# Install to /usr/local/bin
install: build
	@echo "Installing binaries to $(INSTALL_PATH)..."
	sudo cp $(USAGE_BINARY) $(INSTALL_PATH)/
	sudo cp $(QUOTA_BINARY) $(INSTALL_PATH)/
	@echo "Installed successfully. Run: $(USAGE_BINARY) or $(QUOTA_BINARY)"

# Install to ~/bin (no sudo required)
install-local: build
	@echo "Installing binaries to ~/bin..."
	@mkdir -p ~/bin
	cp $(USAGE_BINARY) ~/bin/
	cp $(QUOTA_BINARY) ~/bin/
	@echo "Installed to ~/bin/"
	@echo "Add to PATH: export PATH=\"\$$HOME/bin:\$$PATH\""

# Clean build artifacts
clean:
	@echo "Cleaning..."
	rm -f $(USAGE_BINARY) $(QUOTA_BINARY)
	@echo "Clean complete"

# Run tests (basic smoke tests)
test: build
	@echo "Running tests..."
	@echo "\n==> Usage Tracker Tests"
	@echo "  Help:"
	./$(USAGE_BINARY) --help
	@echo "\n  Default run (30 days):"
	./$(USAGE_BINARY)
	@echo "\n  JSON output:"
	./$(USAGE_BINARY) --json
	@echo "\n==> Quota Tracker Tests"
	@echo "  Help:"
	./$(QUOTA_BINARY) --help
	@echo "\n  Default run:"
	./$(QUOTA_BINARY) || echo "  (requires Claude credentials)"
	@echo "\nTests complete"

# Run usage tracker
run: build-usage
	./$(USAGE_BINARY)

run-daily: build-usage
	./$(USAGE_BINARY) --daily

run-models: build-usage
	./$(USAGE_BINARY) --daily --models

run-json: build-usage
	./$(USAGE_BINARY) --json

# Run quota tracker
run-quota: build-quota
	./$(QUOTA_BINARY)

run-quota-used: build-quota
	./$(QUOTA_BINARY) --used

run-quota-json: build-quota
	./$(QUOTA_BINARY) --json

# Run both tools
run-all: build
	@echo "=== Quota ==="
	./$(QUOTA_BINARY) --no-bars || echo "(requires credentials)"
	@echo ""
	@echo "=== Usage (7 days) ==="
	./$(USAGE_BINARY) -d 7

# Help
help:
	@echo "Claude Usage & Quota Tracker - Makefile"
	@echo ""
	@echo "Build Targets:"
	@echo "  make build         - Compile both binaries"
	@echo "  make build-usage   - Compile usage tracker only"
	@echo "  make build-quota   - Compile quota tracker only"
	@echo ""
	@echo "Install Targets:"
	@echo "  make install       - Install to /usr/local/bin (requires sudo)"
	@echo "  make install-local - Install to ~/bin (no sudo)"
	@echo "  make clean         - Remove build artifacts"
	@echo "  make test          - Run smoke tests"
	@echo ""
	@echo "Usage Tracker (claude-usage):"
	@echo "  make run           - Build and run (30-day summary)"
	@echo "  make run-daily     - Build and run with daily breakdown"
	@echo "  make run-models    - Build and run with model breakdown"
	@echo "  make run-json      - Build and run with JSON output"
	@echo ""
	@echo "Quota Tracker (claude-quota):"
	@echo "  make run-quota     - Build and run quota tracker"
	@echo "  make run-quota-used - Build and run (show percent used)"
	@echo "  make run-quota-json - Build and run (JSON output)"
	@echo ""
	@echo "Combined:"
	@echo "  make run-all       - Run both tools together"
	@echo ""
	@echo "Help:"
	@echo "  make help          - Show this help"

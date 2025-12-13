# Makefile for AI Council Project
# Provides linting, testing, and validation targets

.PHONY: help lint syntax-check test test-security clean all

# Default target - show help
help:
	@echo "AI Council - Available Make Targets:"
	@echo ""
	@echo "  make lint           - Run ShellCheck on all bash scripts"
	@echo "  make syntax-check   - Validate bash syntax without executing"
	@echo "  make test-security  - Run security function tests"
	@echo "  make test           - Run all tests (lint + syntax + security)"
	@echo "  make clean          - Remove temporary test files"
	@echo "  make all            - Run all checks (alias for test)"
	@echo ""

# ShellCheck linting
lint:
	@echo "Running ShellCheck on bash scripts..."
	@shellcheck -s bash terminal_council_with_websearch.sh
	@echo "✓ ShellCheck passed"

# Bash syntax validation
syntax-check:
	@echo "Validating bash syntax..."
	@bash -n terminal_council_with_websearch.sh
	@echo "✓ Syntax check passed"

# Security tests
test-security:
	@echo "Running security function tests..."
	@bash tests/test_security_functions.sh

# Run all tests
test: lint syntax-check test-security
	@echo ""
	@echo "✓ All validation checks passed!"

# Alias for test
all: test

# Clean temporary files
clean:
	@echo "Cleaning temporary files..."
	@rm -rf /tmp/council_test_*
	@echo "✓ Clean complete"

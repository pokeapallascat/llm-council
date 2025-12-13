#!/bin/bash
# Security Function Test Suite
# Tests for is_safe_url and redact_sensitive_data functions

set -euo pipefail

# Colors for test output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Source the main script to get access to functions
# We need to temporarily disable set -e to handle the main script's execution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_SCRIPT="$SCRIPT_DIR/terminal_council_with_websearch.sh"

# Extract just the functions we need to test
# This prevents executing the main script logic
# Get is_safe_url function
IS_SAFE_URL_FUNC=$(sed -n '/^is_safe_url() {$/,/^}$/p' "$MAIN_SCRIPT")
eval "$IS_SAFE_URL_FUNC"

# Get redact_sensitive_data function
REDACT_FUNC=$(sed -n '/^redact_sensitive_data() {$/,/^}$/p' "$MAIN_SCRIPT")
eval "$REDACT_FUNC"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
assert_blocks() {
    local url="$1"
    local description="$2"
    TESTS_RUN=$((TESTS_RUN + 1))

    if is_safe_url "$url" 2>/dev/null; then
        echo -e "${RED}❌ FAIL${NC}: $description"
        echo "   Should block: $url"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    else
        echo -e "${GREEN}✓ PASS${NC}: $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    fi
}

assert_allows() {
    local url="$1"
    local description="$2"
    TESTS_RUN=$((TESTS_RUN + 1))

    if is_safe_url "$url" 2>/dev/null; then
        echo -e "${GREEN}✓ PASS${NC}: $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}❌ FAIL${NC}: $description"
        echo "   Should allow: $url"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_redacts() {
    local input="$1"
    local expected_redaction="$2"
    local description="$3"
    TESTS_RUN=$((TESTS_RUN + 1))

    local output
    output=$(redact_sensitive_data "$input")

    if echo "$output" | grep -qF "$expected_redaction"; then
        echo -e "${GREEN}✓ PASS${NC}: $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}❌ FAIL${NC}: $description"
        echo "   Expected to find: $expected_redaction"
        echo "   Input:  $input"
        echo "   Output: $output"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_not_redacts() {
    local input="$1"
    local description="$2"
    TESTS_RUN=$((TESTS_RUN + 1))

    local output
    output=$(redact_sensitive_data "$input")

    if echo "$output" | grep -qF "[REDACTED"; then
        echo -e "${RED}❌ FAIL${NC}: $description"
        echo "   Should NOT redact: $input"
        echo "   Output: $output"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    else
        echo -e "${GREEN}✓ PASS${NC}: $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    fi
}

# Print test header
echo "================================"
echo "Security Function Test Suite"
echo "================================"
echo ""

# ============================================================================
# TEST SUITE 1: is_safe_url() - SSRF Protection
# ============================================================================

echo "Testing is_safe_url() - SSRF Protection"
echo "----------------------------------------"

# Protocol validation
assert_blocks "ftp://example.com" "Block non-HTTP/HTTPS protocol (ftp)"
assert_blocks "file:///etc/passwd" "Block file:// protocol"
assert_blocks "javascript:alert(1)" "Block javascript: protocol"
assert_allows "http://example.com" "Allow http://"
assert_allows "https://example.com" "Allow https://"

# Localhost variations
assert_blocks "http://localhost" "Block localhost"
assert_blocks "http://localhost:8080" "Block localhost with port"
assert_blocks "https://LOCALHOST" "Block localhost (uppercase)"
assert_blocks "http://127.0.0.1" "Block 127.0.0.1"
assert_blocks "http://127.1.1.1" "Block 127.x.x.x range"
assert_blocks "http://127.255.255.255" "Block 127.255.255.255"
assert_blocks "http://0.0.0.0" "Block 0.0.0.0"
assert_blocks "http://[::1]" "Block IPv6 loopback ::1"

# Private IPv4 ranges (RFC 1918)
assert_blocks "http://10.0.0.1" "Block 10.0.0.0/8"
assert_blocks "http://10.255.255.255" "Block 10.255.255.255"
assert_blocks "http://192.168.0.1" "Block 192.168.0.0/16"
assert_blocks "http://192.168.255.255" "Block 192.168.255.255"
assert_blocks "http://172.16.0.1" "Block 172.16.0.0/12 (start)"
assert_blocks "http://172.20.0.1" "Block 172.16.0.0/12 (middle)"
assert_blocks "http://172.31.255.255" "Block 172.16.0.0/12 (end)"

# Edge case: 172.15 and 172.32 should be allowed (not in RFC1918 range)
assert_allows "http://172.15.0.1" "Allow 172.15.x.x (not in private range)"
assert_allows "http://172.32.0.1" "Allow 172.32.x.x (not in private range)"

# Link-local addresses
assert_blocks "http://169.254.0.1" "Block link-local 169.254.x.x"
assert_blocks "http://169.254.169.254" "Block AWS metadata service"
assert_blocks "http://169.254.255.255" "Block link-local max"

# IPv6 private ranges
assert_blocks "http://[fc00::1]" "Block IPv6 ULA fc00::/7"
assert_blocks "http://[fd00::1]" "Block IPv6 ULA fd00::/8"
assert_blocks "http://[fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]" "Block IPv6 ULA range end"
assert_blocks "http://[fe80::1]" "Block IPv6 link-local fe80::/10"
assert_blocks "http://[fe80::ffff:ffff:ffff:ffff]" "Block IPv6 link-local range"
assert_blocks "http://[::ffff:127.0.0.1]" "Block IPv4-mapped IPv6 loopback"

# Cloud metadata services
assert_blocks "http://169.254.169.254/latest/meta-data/" "Block AWS metadata endpoint"
assert_blocks "http://metadata.google.internal" "Block Google Cloud metadata"
assert_blocks "http://metadata.google.com" "Block Google metadata alternate"
assert_blocks "http://169.254.169.254.nip.io" "Block metadata via nip.io"

# Hexadecimal IP notation
assert_blocks "http://0x7f000001" "Block hex notation for 127.0.0.1"
assert_blocks "http://0x7f.0x0.0x0.0x1" "Block mixed hex notation"
assert_blocks "http://0xc0a80001" "Block hex notation for 192.168.0.1"

# Valid public URLs (should be allowed)
assert_allows "https://www.google.com" "Allow google.com"
assert_allows "https://github.com/user/repo" "Allow github.com"
assert_allows "http://example.com:8080/path" "Allow public domain with port"
assert_allows "https://api.openai.com/v1/chat" "Allow OpenAI API"
assert_allows "https://192.0.2.1" "Allow TEST-NET-1 (192.0.2.0/24)"
assert_allows "https://198.51.100.1" "Allow TEST-NET-2 (198.51.100.0/24)"
assert_allows "https://203.0.113.1" "Allow TEST-NET-3 (203.0.113.0/24)"
assert_allows "http://8.8.8.8" "Allow Google DNS (public IP)"

echo ""

# ============================================================================
# TEST SUITE 2: redact_sensitive_data() - Secret Redaction
# ============================================================================

echo "Testing redact_sensitive_data() - Secret Redaction"
echo "--------------------------------------------------"

# OpenAI API keys
assert_redacts "sk-1234567890abcdefghijklmnopqrstuvwxyz" "[REDACTED_API_KEY]" "Redact OpenAI API key (sk-)"

# Generic API keys
assert_redacts "api_key=secret123456" "[REDACTED]" "Redact api_key parameter"
assert_redacts "apikey=secret123456" "[REDACTED]" "Redact apikey parameter"
assert_redacts "API_KEY=secret123456" "[REDACTED]" "Redact API_KEY (uppercase)"

# GitHub tokens
assert_redacts "ghp_1234567890123456789012345678901234567890" "[REDACTED_GITHUB_TOKEN]" "Redact GitHub PAT (ghp_)"
assert_redacts "gho_1234567890123456789012345678901234567890" "[REDACTED_GITHUB_TOKEN]" "Redact GitHub OAuth (gho_)"
assert_redacts "ghs_1234567890123456789012345678901234567890" "[REDACTED_GITHUB_TOKEN]" "Redact GitHub server token (ghs_)"

# Google API keys (39 chars total: AIza + 35 more)
assert_redacts "AIzaSyD12345678901234567890123456789012" "[REDACTED_GOOGLE_KEY]" "Redact Google API key (AIza)"

# Bearer tokens
assert_redacts "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" "[REDACTED]" "Redact Bearer token"
assert_redacts "bearer abc123def456ghi789jkl012mno345pqr678" "[REDACTED]" "Redact bearer (lowercase)"

# Authorization headers
assert_redacts "Authorization: Basic dXNlcjpwYXNz" "[REDACTED]" "Redact Authorization header"

# JWT tokens
assert_redacts "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c" "[REDACTED_JWT]" "Redact JWT token"

# Token parameters
assert_redacts "token=abc123def456ghi789" "[REDACTED]" "Redact token parameter"
assert_redacts "access_token=secret123456" "[REDACTED]" "Redact access_token parameter"
assert_redacts "access-token=secret123456" "[REDACTED]" "Redact access-token parameter"

# Passwords in URLs
assert_redacts "https://user:password123@example.com" "[REDACTED]" "Redact password in URL"
assert_redacts "http://admin:secret@api.example.com/path" "[REDACTED]" "Redact password in URL with path"
assert_redacts "password=mySecretPass123" "[REDACTED]" "Redact password parameter"
assert_redacts "passwd=mySecretPass123" "[REDACTED]" "Redact passwd parameter"

# Database connection strings
assert_redacts "postgres://user:pass@localhost:5432/db" "[REDACTED]" "Redact PostgreSQL URI"
assert_redacts "mysql://root:password@127.0.0.1:3306/mydb" "[REDACTED]" "Redact MySQL URI"
assert_redacts "mongodb://admin:secret@localhost:27017/db" "[REDACTED]" "Redact MongoDB URI"
assert_redacts "redis://user:pass@localhost:6379" "[REDACTED]" "Redact Redis URI"

# Secret keys
assert_redacts "secret_key=abc123def456" "[REDACTED]" "Redact secret_key parameter"
assert_redacts "secret-key=abc123def456" "[REDACTED]" "Redact secret-key parameter"
assert_redacts "client_secret=xyz789abc123" "[REDACTED]" "Redact client_secret parameter"
assert_redacts "client-secret=xyz789abc123" "[REDACTED]" "Redact client-secret parameter"

# AWS keys (20 chars total: AKIA + 16 more)
assert_redacts "AKIAIOSFODNN7EXAMPLE" "[REDACTED_AWS_KEY]" "Redact AWS access key"
assert_redacts "AKIAJK3EXAMPLE7ABCDE" "[REDACTED_AWS_KEY]" "Redact AWS access key variant"

# Private keys
assert_redacts "-----BEGIN PRIVATE KEY-----" "[REDACTED_PRIVATE_KEY]" "Redact private key header"
assert_redacts "-----BEGIN RSA PRIVATE KEY-----" "[REDACTED_PRIVATE_KEY]" "Redact RSA private key header"
assert_redacts "-----BEGIN EC PRIVATE KEY-----" "[REDACTED_PRIVATE_KEY]" "Redact EC private key header"

# Safe strings (should NOT be redacted)
assert_not_redacts "This is a normal sentence with no secrets." "Normal text not redacted"
assert_not_redacts "The API documentation is available online." "Word 'API' not redacted"
assert_not_redacts "Please enter your password in the form." "Word 'password' not redacted"
assert_not_redacts "The secret to success is hard work." "Word 'secret' not redacted"
assert_not_redacts "Bearer bonds are financial instruments." "Word 'Bearer' not redacted"

echo ""

# ============================================================================
# TEST SUMMARY
# ============================================================================

echo "================================"
echo "Test Summary"
echo "================================"
echo "Total tests run: $TESTS_RUN"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
else
    echo "Failed: $TESTS_FAILED"
fi
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}❌ Some tests failed!${NC}"
    echo ""
    exit 1
fi

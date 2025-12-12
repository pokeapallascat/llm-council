#!/bin/bash

# Terminal LLM Council with Web Search Integration
# Uses local CLI tools: openai, claude, and gemini
# Integrates with open-webSearch MCP server for research capabilities

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Bash version check (now Bash 3.2 compatible)
if [ "${BASH_VERSINFO[0]:-0}" -lt 3 ]; then
    echo -e "${RED}Error:${NC} Bash 3+ is required." >&2
    echo "Current Bash version: ${BASH_VERSION:-unknown}" >&2
    exit 1
fi

# Debug logging toggle
COUNCIL_DEBUG=${COUNCIL_DEBUG:-""}

# Default configuration (overridable via env vars)
OPENAI_MODEL=${OPENAI_MODEL:-"gpt-5.1"}
CLAUDE_MODEL=${CLAUDE_MODEL:-"sonnet"}
GEMINI_MODEL=${GEMINI_MODEL:-"gemini-2.5-pro"}
MODEL_IDS=("openai" "claude" "gemini")
CHAIRMAN=${CHAIRMAN:-"openai"}
OPENAI_TOOL=""
OPENAI_DISPLAY=""

# Timeouts (seconds)
MODEL_TIMEOUT_SECONDS=${MODEL_TIMEOUT_SECONDS:-45}
WEB_SEARCH_TIMEOUT=${WEB_SEARCH_TIMEOUT:-20}

# Timeout command (best effort; falls back to no timeout if unavailable)
TIMEOUT_CMD=$(command -v timeout || true)

# Web search configuration
WEBSEARCH_URL=${WEBSEARCH_URL:-"http://localhost:3000"}
ENABLE_WEB_SEARCH=${ENABLE_WEB_SEARCH:-"true"}
WEBSEARCH_ENGINES=${WEBSEARCH_ENGINES:-"duckduckgo,brave"}
# Fetch URL content configuration (per-model enrichment)
FETCH_URL_ENABLE=${FETCH_URL_ENABLE:-"true"}
FETCH_URL_RESULTS=${FETCH_URL_RESULTS:-5}           # how many top URLs to fetch content for
FETCH_URL_MAX_CHARS=${FETCH_URL_MAX_CHARS:-8000}    # truncate fetched content (increased for more context)

# Response length configuration (max output tokens)
MAX_TOKENS_STAGE1=${MAX_TOKENS_STAGE1:-4000}        # Initial responses with research (detailed)
MAX_TOKENS_STAGE2=${MAX_TOKENS_STAGE2:-500}         # Peer reviews (concise)
MAX_TOKENS_STAGE3=${MAX_TOKENS_STAGE3:-6000}        # Final synthesis (comprehensive)

# Performance & optional features
COUNCIL_AI_TITLES=${COUNCIL_AI_TITLES:-"true"}      # Use AI to generate session filenames (false = use deterministic sanitized query)

# Token tracking (bash 3.2 compatible - using separate variables per model)
OPENAI_INPUT_TOKENS=0
OPENAI_OUTPUT_TOKENS=0
OPENAI_TOTAL_TOKENS=0
CLAUDE_INPUT_TOKENS=0
CLAUDE_OUTPUT_TOKENS=0
CLAUDE_TOTAL_TOKENS=0
GEMINI_INPUT_TOKENS=0
GEMINI_OUTPUT_TOKENS=0
GEMINI_TOTAL_TOKENS=0
TOTAL_INPUT_TOKENS=0
TOTAL_OUTPUT_TOKENS=0

# Temporary directory for responses
TEMP_DIR=$(mktemp -d)
chmod 700 "$TEMP_DIR"  # Restrict access to owner only
trap 'rm -rf "$TEMP_DIR"' EXIT

print_header() {
    echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}$1${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_model() {
    echo -e "${BOLD}${GREEN}[$1]${NC}"
}

debug_log() {
    if [ "${COUNCIL_DEBUG}" = "true" ]; then
        # Redact sensitive data before logging
        local safe_msg
        safe_msg=$(redact_sensitive_data "$*")
        echo -e "${YELLOW}[DEBUG]${NC} $safe_msg" >&2
    fi
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}Error:${NC} Required command '$cmd' is not available in PATH."
        exit 1
    fi
}

model_exists() {
    local needle="$1"
    for entry in "${MODEL_IDS[@]}"; do
        if [ "$entry" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

run_with_timeout() {
    local seconds="$1"
    shift
    if [ -n "$TIMEOUT_CMD" ]; then
        "$TIMEOUT_CMD" "$seconds" "$@"
    else
        "$@"
    fi
}

get_model_label() {
    case "$1" in
        openai) echo "$OPENAI_DISPLAY" ;;
        claude) echo "Claude CLI (${CLAUDE_MODEL})" ;;
        gemini) echo "Gemini CLI (${GEMINI_MODEL})" ;;
        *) echo "$1" ;;
    esac
}

# Estimate tokens from text (rough approximation: 1 token ≈ 4 characters)
estimate_tokens() {
    local text="$1"
    local char_count=${#text}
    echo $(( char_count / 4 ))
}

# Track token usage for a model (bash 3.2 compatible)
track_tokens() {
    local model="$1"
    local input_tokens="$2"
    local output_tokens="$3"

    # Accumulate per model using case statement
    case "$model" in
        openai)
            OPENAI_INPUT_TOKENS=$(( OPENAI_INPUT_TOKENS + input_tokens ))
            OPENAI_OUTPUT_TOKENS=$(( OPENAI_OUTPUT_TOKENS + output_tokens ))
            OPENAI_TOTAL_TOKENS=$(( OPENAI_TOTAL_TOKENS + input_tokens + output_tokens ))
            ;;
        claude)
            CLAUDE_INPUT_TOKENS=$(( CLAUDE_INPUT_TOKENS + input_tokens ))
            CLAUDE_OUTPUT_TOKENS=$(( CLAUDE_OUTPUT_TOKENS + output_tokens ))
            CLAUDE_TOTAL_TOKENS=$(( CLAUDE_TOTAL_TOKENS + input_tokens + output_tokens ))
            ;;
        gemini)
            GEMINI_INPUT_TOKENS=$(( GEMINI_INPUT_TOKENS + input_tokens ))
            GEMINI_OUTPUT_TOKENS=$(( GEMINI_OUTPUT_TOKENS + output_tokens ))
            GEMINI_TOTAL_TOKENS=$(( GEMINI_TOTAL_TOKENS + input_tokens + output_tokens ))
            ;;
    esac

    # Update global totals
    TOTAL_INPUT_TOKENS=$(( TOTAL_INPUT_TOKENS + input_tokens ))
    TOTAL_OUTPUT_TOKENS=$(( TOTAL_OUTPUT_TOKENS + output_tokens ))
}

# ============================================================================
# SESSION DOCUMENTATION FUNCTIONS
# ============================================================================

# Sanitize question for use as filename
# Generate a short descriptive title using Codex (max 20 chars)
generate_short_title() {
    local query="$1"
    local short_title=""

    # Check if AI title generation is enabled (performance optimization)
    if [ "${COUNCIL_AI_TITLES:-true}" = "true" ]; then
        local title_prompt="Summarize this question into a short file title (max 20 characters, lowercase, use underscores instead of spaces, no special characters). Only respond with the title, nothing else.

Question: $query"

        # Call Codex with minimal tokens for quick response
        # Capture in failure-tolerant step to prevent strict-mode pipeline abort
        local raw_title
        raw_title=$(run_openai "$title_prompt" "low" "50" 2>/dev/null || true)

        # Process if we got a response
        if [ -n "$raw_title" ]; then
            # Performance: combine sed passes into single invocation
            short_title=$(echo "$raw_title" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_]/_/g' -e 's/__*/_/g' -e 's/^_//;s/_$//' | cut -c1-20)
        fi
    fi

    # Fallback: use deterministic sanitized query if AI disabled or failed
    if [ -z "$short_title" ]; then
        # Performance: combine sed passes into single invocation
        short_title=$(echo "$query" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/_/g' -e 's/__*/_/g' -e 's/_$//' | cut -c1-20)
    fi

    echo "$short_title"
}

# Save complete session documentation
save_session_documentation() {
    local sessions_dir="council_sessions"
    mkdir -p "$sessions_dir"

    # Generate short descriptive title using Codex
    local date_only
    date_only=$(date +"%Y-%m-%d")
    local short_title
    short_title=$(generate_short_title "$QUERY")

    # Atomically allocate session filename using noclobber (prevents race conditions)
    local base_pattern="${date_only}_${short_title}"
    local version=""
    local version_num=1
    local filename

    # Try to create file exclusively in a loop until we find an available name
    while true; do
        if [ "$version_num" -gt 1 ]; then
            version="v${version_num}_"
        else
            version=""
        fi
        filename="${sessions_dir}/${version}${date_only}_${short_title}.md"

        # Try to create file exclusively using noclobber
        # This is atomic and prevents race conditions
        if ( set -C; : > "$filename" ) 2>/dev/null; then
            # Successfully created file exclusively - break out of loop
            break
        fi

        # File exists, try next version number
        ((version_num++))

        # Safety check: prevent infinite loop
        if [ "$version_num" -gt 100 ]; then
            echo "Error: Could not allocate session filename after 100 attempts" >&2
            filename="${sessions_dir}/fallback_${date_only}_${RANDOM}.md"
            break
        fi
    done

    {
        # Redact sensitive data from query before saving
        local redacted_query
        redacted_query=$(redact_sensitive_data "$QUERY")

        echo "# Council Session: $redacted_query"
        echo ""
        echo "**Date:** $(date '+%Y-%m-%d %H:%M:%S')"
        echo "**Council Members:** $COUNCIL_SUMMARY"
        echo "**Chairman:** $CHAIRMAN_LABEL"
        if [ "$ENABLE_WEB_SEARCH_FOR_QUERY" = true ]; then
            echo "**Web Research:** Enabled (${FETCH_URL_RESULTS} URLs × ${FETCH_URL_MAX_CHARS} chars each)"
        else
            echo "**Web Research:** Disabled"
        fi
        echo ""
        echo "---"
        echo ""

        # Stage 1: Initial Responses with Web Research
        echo "## Stage 1: Independent Research & Responses"
        echo ""
        for model in "${MODEL_IDS[@]}"; do
            label=$(get_model_label "$model")
            echo "### $label"
            echo ""

            # Include explicit URLs content if available (shared across all models)
            local explicit_urls_file
            explicit_urls_file="$TEMP_DIR/explicit_urls_content.txt"
            if [ -f "$explicit_urls_file" ] && [ -s "$explicit_urls_file" ]; then
                echo "#### Explicit URLs Fetched"
                echo ""
                echo "**Content from URLs in query:**"
                echo '```'
                redact_sensitive_data "$(cat "$explicit_urls_file")"
                echo '```'
                echo ""
            fi

            # Include web research data if available
            local search_file
            local content_file
            search_file="$TEMP_DIR/${model}_search_results.txt"
            content_file="$TEMP_DIR/${model}_fetched_content.txt"

            if [ -f "$search_file" ] && [ -s "$search_file" ]; then
                echo "#### Web Research Performed"
                echo ""
                echo "**Search Results:**"
                echo '```'
                redact_sensitive_data "$(cat "$search_file")"
                echo '```'
                echo ""
            fi

            if [ -f "$content_file" ] && [ -s "$content_file" ]; then
                echo "**Full Content Fetched:**"
                echo '```'
                redact_sensitive_data "$(cat "$content_file")"
                echo '```'
                echo ""
            fi

            echo "#### Response"
            echo ""
            redact_sensitive_data "$(cat "$TEMP_DIR/${model}_response.txt")"
            echo ""
            echo ""
        done

        # Stage 2: Peer Reviews
        echo "---"
        echo ""
        echo "## Stage 2: Peer Reviews"
        echo ""
        for reviewer in "${MODEL_IDS[@]}"; do
            reviewer_label=$(get_model_label "$reviewer")
            echo "### Reviews by $reviewer_label"
            echo ""
            for reviewee in "${MODEL_IDS[@]}"; do
                if [ "$reviewer" = "$reviewee" ]; then
                    continue
                fi
                reviewee_label=$(get_model_label "$reviewee")
                review_path="$TEMP_DIR/review_${reviewer}_${reviewee}.txt"
                if [ -s "$review_path" ]; then
                    echo "#### Reviewing $reviewee_label"
                    echo ""
                    redact_sensitive_data "$(cat "$review_path")"
                    echo ""
                fi
            done
            echo ""
        done

        # Stage 3: Final Synthesis
        echo "---"
        echo ""
        echo "## Stage 3: Final Synthesis"
        echo ""
        echo "### $CHAIRMAN_LABEL (Chairman)"
        echo ""
        redact_sensitive_data "$FINAL_RESPONSE"
        echo ""
        echo ""

        # Token Usage Report
        echo "---"
        echo ""
        echo "## Token Usage Report"
        echo ""
        echo "### Per-Model Token Usage"
        echo ""
        for model in "${MODEL_IDS[@]}"; do
            label=$(get_model_label "$model")
            case "$model" in
                openai)
                    echo "- **$label**: Input: $OPENAI_INPUT_TOKENS | Output: $OPENAI_OUTPUT_TOKENS | Total: $OPENAI_TOTAL_TOKENS"
                    ;;
                claude)
                    echo "- **$label**: Input: $CLAUDE_INPUT_TOKENS | Output: $CLAUDE_OUTPUT_TOKENS | Total: $CLAUDE_TOTAL_TOKENS"
                    ;;
                gemini)
                    echo "- **$label**: Input: $GEMINI_INPUT_TOKENS | Output: $GEMINI_OUTPUT_TOKENS | Total: $GEMINI_TOTAL_TOKENS"
                    ;;
            esac
        done
        echo ""
        echo "### Overall Token Usage"
        echo ""
        grand_total=$((TOTAL_INPUT_TOKENS + TOTAL_OUTPUT_TOKENS))
        echo "- **Total Input:** $TOTAL_INPUT_TOKENS tokens"
        echo "- **Total Output:** $TOTAL_OUTPUT_TOKENS tokens"
        echo "- **Grand Total:** $grand_total tokens"
        echo ""
        echo "---"
        echo ""
        echo "*Session documentation generated by Terminal LLM Council*"

    } > "$filename"

    echo "$filename"
}

# ============================================================================
# WEB SEARCH HELPER FUNCTIONS
# ============================================================================

# Check if web search server is available
check_websearch_server() {
    # Allow TRUE/true/True; anything else is treated as disabled
    local enable_lower
    enable_lower=$(echo "$ENABLE_WEB_SEARCH" | tr '[:upper:]' '[:lower:]')
    if [ "$enable_lower" != "true" ]; then
        return 1
    fi

    if run_with_timeout "$WEB_SEARCH_TIMEOUT" curl -s -f "${WEBSEARCH_URL}/api/health" >/dev/null 2>&1; then
        return 0
    else
        echo -e "${YELLOW}Warning:${NC} Web search server not available at ${WEBSEARCH_URL}" >&2
        return 1
    fi
}

# Perform web search using REST API
web_search() {
    local query="$1"
    local limit="${2:-5}"
    local payload

    payload=$(jq -nc \
        --arg query "$query" \
        --argjson limit "$limit" \
        --arg engines "$WEBSEARCH_ENGINES" \
        '{query: $query, limit: $limit,
          engines: ($engines | split(",") | map(gsub("^\\s+|\\s+$"; "")))}')

    debug_log "web_search: q=\"$query\" limit=$limit"
    run_with_timeout "$WEB_SEARCH_TIMEOUT" curl -s -X POST "${WEBSEARCH_URL}/api/search" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        | jq -r '.results[] | "Title: \(.title)\nURL: \(.url)\nDescription: \(.description)\n---"' 2>/dev/null || echo ""
}

# Perform web search and return raw JSON results
web_search_json() {
    local query="$1"
    local limit="${2:-5}"
    local payload
    local result

    payload=$(jq -nc \
        --arg query "$query" \
        --argjson limit "$limit" \
        --arg engines "$WEBSEARCH_ENGINES" \
        '{query: $query, limit: $limit,
          engines: ($engines | split(",") | map(gsub("^\\s+|\\s+$"; "")))}')

    debug_log "web_search_json: q=\"$query\" limit=$limit"

    # Graceful degradation: return empty on failure instead of aborting
    if ! result=$(run_with_timeout "$WEB_SEARCH_TIMEOUT" curl -s -X POST "${WEBSEARCH_URL}/api/search" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null); then
        debug_log "Web search API call failed, returning empty results"
        echo ""
        return 1
    fi

    echo "$result"
    return 0
}

# Fetch content from a specific URL
fetch_url_content() {
    local url="$1"
    local payload

    payload=$(jq -nc --arg url "$url" '{url: $url, useBrowserFallback: true}')

    debug_log "fetch_url_content: url=\"$url\""
    run_with_timeout "$WEB_SEARCH_TIMEOUT" curl -s -X POST "${WEBSEARCH_URL}/api/fetchUrl" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        | jq -r '.content' 2>/dev/null || echo ""
}

# Fetch content with truncation
fetch_url_content_limited() {
    local url="$1"
    local payload

    payload=$(jq -nc --arg url "$url" --argjson maxLen "$FETCH_URL_MAX_CHARS" '{url: $url, useBrowserFallback: true, maxContentLength: $maxLen}')

    debug_log "fetch_url_content_limited: url=\"$url\" maxLen=$FETCH_URL_MAX_CHARS"
    run_with_timeout "$WEB_SEARCH_TIMEOUT" curl -s -X POST "${WEBSEARCH_URL}/api/fetchUrl" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        | jq -r '.content' 2>/dev/null || echo ""
}

# Determine if query needs web search (detects explicit requests or asks GPT-5.1 w/ higher reasoning)
needs_web_search() {
    local query="$1"
    local query_lower
    query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')

    # Check for explicit search request keywords
    if [[ "$query_lower" =~ (search|find|look.up|fetch|get.news|latest|current|recent|today|web.search) ]]; then
        return 0
    fi

    # For now, rely only on keyword heuristics to avoid potential hangs
    # TODO: Re-enable AI-based decision after investigating timeout issues
    return 1
}

# Generate model-specific search queries (per-model query planning)
generate_search_queries_for_model() {
    local model="$1"
    local user_query="$2"
    local max_queries="${3:-5}"
    local planning_start=$SECONDS

    # Planning prompt for the model
    local planning_prompt="You are planning web research to answer this question:
\"${user_query}\"

Your task is to break this down into 3-${max_queries} focused search queries that will help you gather the information needed.

INSTRUCTIONS:
1. Identify distinct information goals (e.g., product details, team info, market analysis, etc.)
2. For each goal, create 1-2 concise search queries
3. Use clear, specific terms that search engines understand well
4. If the question mentions specific entities (companies, products), include those names
5. Prefer queries that will find authoritative sources (whitepapers, official docs, research papers)
6. If recency matters (e.g., \"latest\", \"current\"), include temporal terms (2025, recent, latest)

OUTPUT FORMAT:
Return ONLY the search queries, one per line, nothing else.
No explanations, no numbering, no bullet points.

Example good output:
blockchain DeFi tokenomics model
crypto project founders background
decentralized prediction markets comparison 2025
Web3 go-to-market strategy analysis

Now generate your search queries:"

    # Call the model to generate queries (low reasoning for planning, small token budget)
    local queries_text
    debug_log "Planning queries for model=$model (max=${max_queries})"
    case "$model" in
        openai)
            # Use low reasoning for planning to avoid preamble and save tokens
            queries_text=$(run_openai "$planning_prompt" "low" 500 2>/dev/null || echo "")
            ;;
        claude|gemini)
            # Claude and Gemini don't have reasoning levels, use invoke_model
            queries_text=$(invoke_model "$model" "$planning_prompt" 500 2>/dev/null || echo "")
            ;;
        *)
            queries_text=""
            ;;
    esac

    # Parse and validate: take first N non-empty lines
    local -a queries=()
    while IFS= read -r line; do
        # Strip leading/trailing whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Skip empty lines, number-only lines, or lines starting with #
        if [ -n "$line" ] && ! [[ "$line" =~ ^[0-9]+\.?$ ]] && ! [[ "$line" =~ ^# ]]; then
            queries+=("$line")
        fi

        # Stop at max_queries
        [ "${#queries[@]}" -ge "$max_queries" ] && break
    done <<< "$queries_text"

    # Fallback: if we got 0 queries, return the original question
    if [ "${#queries[@]}" -eq 0 ]; then
        debug_log "Planning for model=$model returned 0 queries (fallback to original question) in $((SECONDS - planning_start))s"
        echo "$user_query"
        return 0
    fi

    debug_log "Planning for model=$model produced ${#queries[@]} queries in $((SECONDS - planning_start))s"

    # Return queries, one per line
    printf '%s\n' "${queries[@]}"
}

# ============================================================================
# SECURITY & PRIVACY FUNCTIONS
# ============================================================================

# Validate URL is safe to fetch (prevent SSRF attacks)
is_safe_url() {
    local url="$1"

    # Only allow http and https protocols
    if [[ ! "$url" =~ ^https?:// ]]; then
        echo "URL must use http or https protocol" >&2
        return 1
    fi

    # Extract hostname/IP from URL (handle IPv6 brackets)
    local host
    host=$(echo "$url" | sed -E 's|^https?://([^:/]+).*|\1|')

    # Remove IPv6 brackets if present
    host=$(echo "$host" | sed -E 's/^\[(.+)\]$/\1/')

    # Block localhost variations
    if [[ "$host" =~ ^(localhost|127\.|::1|0\.0\.0\.0)$ ]]; then
        echo "Blocked: localhost/loopback addresses not allowed" >&2
        return 1
    fi

    # Block private IPv4 ranges (RFC 1918)
    if [[ "$host" =~ ^10\. ]] || \
       [[ "$host" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
       [[ "$host" =~ ^192\.168\. ]]; then
        echo "Blocked: private IP addresses not allowed" >&2
        return 1
    fi

    # Block link-local IPv4 addresses
    if [[ "$host" =~ ^169\.254\. ]]; then
        echo "Blocked: link-local addresses not allowed" >&2
        return 1
    fi

    # Block IPv6 private/local ranges
    # fc00::/7 and fd00::/8 (Unique Local Addresses)
    if [[ "$host" =~ ^f[cd][0-9a-fA-F]{2}: ]]; then
        echo "Blocked: IPv6 private addresses not allowed" >&2
        return 1
    fi

    # fe80::/10 (Link-Local)
    if [[ "$host" =~ ^fe80: ]]; then
        echo "Blocked: IPv6 link-local addresses not allowed" >&2
        return 1
    fi

    # ::ffff:127.0.0.0/104 (IPv4-mapped loopback)
    if [[ "$host" =~ ^::ffff:127\. ]]; then
        echo "Blocked: IPv4-mapped loopback not allowed" >&2
        return 1
    fi

    # Block metadata services (cloud providers)
    if [[ "$host" =~ ^169\.254\.169\.254$ ]] || \
       [[ "$host" = "metadata.google.internal" ]] || \
       [[ "$host" = "metadata.google.com" ]] || \
       [[ "$host" = "169.254.169.254.nip.io" ]]; then
        echo "Blocked: cloud metadata service not allowed" >&2
        return 1
    fi

    # Block hexadecimal IP notation (e.g., 0x7f000001 = 127.0.0.1)
    if [[ "$host" =~ ^0x[0-9a-fA-F]+$ ]]; then
        echo "Blocked: hexadecimal IP notation not allowed" >&2
        return 1
    fi

    return 0
}

# Redact sensitive data from text
redact_sensitive_data() {
    local text="$1"

    # Redact common API key patterns
    text=$(echo "$text" | sed -E 's/(sk-[a-zA-Z0-9]{20,})/[REDACTED_API_KEY]/g')
    text=$(echo "$text" | sed -E 's/(api[-_]?key=)[^&[:space:]]+/\1[REDACTED]/gi')
    text=$(echo "$text" | sed -E 's/(apikey=)[^&[:space:]]+/\1[REDACTED]/gi')

    # Redact GitHub tokens (ghp_, gho_, ghs_, ghr_, ghu_, etc.)
    text=$(echo "$text" | sed -E 's/(gh[psoura]_[a-zA-Z0-9]{36,})/[REDACTED_GITHUB_TOKEN]/g')

    # Redact Google API keys (AIza...)
    text=$(echo "$text" | sed -E 's/AIza[0-9A-Za-z_-]{35}/[REDACTED_GOOGLE_KEY]/g')

    # Redact Bearer tokens
    text=$(echo "$text" | sed -E 's/(Bearer[[:space:]]+)[a-zA-Z0-9._-]{20,}/\1[REDACTED]/gi')
    text=$(echo "$text" | sed -E 's/(Authorization:[[:space:]]*)[^[:space:]]+/\1[REDACTED]/gi')

    # Redact JWT tokens (rough pattern: xxx.yyy.zzz format)
    text=$(echo "$text" | sed -E 's/eyJ[a-zA-Z0-9_-]+\.eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+/[REDACTED_JWT]/g')

    # Redact tokens in URLs
    text=$(echo "$text" | sed -E 's/(token=)[^&[:space:]]+/\1[REDACTED]/gi')
    text=$(echo "$text" | sed -E 's/(access[-_]?token=)[^&[:space:]]+/\1[REDACTED]/gi')

    # Redact passwords in URLs
    text=$(echo "$text" | sed -E 's|(://[^:]+:)[^@]+(@)|\1[REDACTED]\2|g')
    text=$(echo "$text" | sed -E 's/(password=)[^&[:space:]]+/\1[REDACTED]/gi')
    text=$(echo "$text" | sed -E 's/(passwd=)[^&[:space:]]+/\1[REDACTED]/gi')

    # Redact database connection strings (BSD sed compatible - use | delimiter to avoid @ conflicts)
    text=$(echo "$text" | sed -E 's|(postgres|mysql|mongodb|redis)://[^:]+:[^@]+@|\1://[REDACTED]:[REDACTED]@|g')

    # Redact secret keys
    text=$(echo "$text" | sed -E 's/(secret[-_]?key=)[^&[:space:]]+/\1[REDACTED]/gi')
    text=$(echo "$text" | sed -E 's/(client[-_]?secret=)[^&[:space:]]+/\1[REDACTED]/gi')

    # Redact AWS keys
    text=$(echo "$text" | sed -E 's/AKIA[0-9A-Z]{16}/[REDACTED_AWS_KEY]/g')

    # Redact private keys (simple pattern - matches single line headers)
    text=$(echo "$text" | sed -E 's/-----BEGIN.*PRIVATE KEY-----/[REDACTED_PRIVATE_KEY]/g')
    text=$(echo "$text" | sed -E 's/-----END.*PRIVATE KEY-----//g')

    # Redact email addresses (optional - controlled by COUNCIL_REDACT_EMAILS)
    if [ "${COUNCIL_REDACT_EMAILS:-false}" = "true" ]; then
        text=$(echo "$text" | sed -E 's/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/[REDACTED_EMAIL]/g')
    fi

    echo "$text"
}

# Validate numeric environment variables
validate_numeric_env_vars() {
    local errors=0

    # Validate FETCH_URL_RESULTS
    if ! [[ "$FETCH_URL_RESULTS" =~ ^[0-9]+$ ]] || [ "$FETCH_URL_RESULTS" -lt 1 ]; then
        echo -e "${RED}Error:${NC} FETCH_URL_RESULTS must be a positive integer (got: '$FETCH_URL_RESULTS')" >&2
        ((errors++))
    fi

    # Validate FETCH_URL_MAX_CHARS
    if ! [[ "$FETCH_URL_MAX_CHARS" =~ ^[0-9]+$ ]] || [ "$FETCH_URL_MAX_CHARS" -lt 100 ]; then
        echo -e "${RED}Error:${NC} FETCH_URL_MAX_CHARS must be >= 100 (got: '$FETCH_URL_MAX_CHARS')" >&2
        ((errors++))
    fi

    # Validate MAX_TOKENS_STAGE1
    if ! [[ "$MAX_TOKENS_STAGE1" =~ ^[0-9]+$ ]] || [ "$MAX_TOKENS_STAGE1" -lt 100 ]; then
        echo -e "${RED}Error:${NC} MAX_TOKENS_STAGE1 must be >= 100 (got: '$MAX_TOKENS_STAGE1')" >&2
        ((errors++))
    fi

    # Validate MAX_TOKENS_STAGE2
    if ! [[ "$MAX_TOKENS_STAGE2" =~ ^[0-9]+$ ]] || [ "$MAX_TOKENS_STAGE2" -lt 50 ]; then
        echo -e "${RED}Error:${NC} MAX_TOKENS_STAGE2 must be >= 50 (got: '$MAX_TOKENS_STAGE2')" >&2
        ((errors++))
    fi

    # Validate MAX_TOKENS_STAGE3
    if ! [[ "$MAX_TOKENS_STAGE3" =~ ^[0-9]+$ ]] || [ "$MAX_TOKENS_STAGE3" -lt 100 ]; then
        echo -e "${RED}Error:${NC} MAX_TOKENS_STAGE3 must be >= 100 (got: '$MAX_TOKENS_STAGE3')" >&2
        ((errors++))
    fi

    # Validate MODEL_TIMEOUT_SECONDS
    if ! [[ "$MODEL_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$MODEL_TIMEOUT_SECONDS" -lt 1 ]; then
        echo -e "${RED}Error:${NC} MODEL_TIMEOUT_SECONDS must be a positive integer (got: '$MODEL_TIMEOUT_SECONDS')" >&2
        ((errors++))
    fi

    # Validate WEB_SEARCH_TIMEOUT
    if ! [[ "$WEB_SEARCH_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$WEB_SEARCH_TIMEOUT" -lt 1 ]; then
        echo -e "${RED}Error:${NC} WEB_SEARCH_TIMEOUT must be a positive integer (got: '$WEB_SEARCH_TIMEOUT')" >&2
        ((errors++))
    fi

    if [ $errors -gt 0 ]; then
        return 1
    fi
    return 0
}

# Validate WEBSEARCH_URL is a trusted localhost URL
validate_websearch_url() {
    # Only allow localhost URLs for security (fail-closed by default)
    if [[ ! "$WEBSEARCH_URL" =~ ^http://localhost:[0-9]+$ ]] && \
       [[ ! "$WEBSEARCH_URL" =~ ^http://127\.0\.0\.1:[0-9]+$ ]]; then

        # Check for explicit opt-in to allow external endpoints
        if [ "${COUNCIL_ALLOW_EXTERNAL_WEBSEARCH:-false}" != "true" ]; then
            echo -e "${RED}Error:${NC} WEBSEARCH_URL must use localhost for security (current: $WEBSEARCH_URL)" >&2
            echo -e "${RED}       Using external URLs may expose your queries to third parties${NC}" >&2
            echo -e "${YELLOW}       To allow external endpoints, set: COUNCIL_ALLOW_EXTERNAL_WEBSEARCH=true${NC}" >&2
            return 1
        else
            echo -e "${YELLOW}Warning:${NC} Using external WEBSEARCH_URL: $WEBSEARCH_URL" >&2
            echo -e "${YELLOW}         COUNCIL_ALLOW_EXTERNAL_WEBSEARCH is enabled - queries may be exposed${NC}" >&2
        fi
    fi
    return 0
}

# Validate string environment variables for shell metacharacters
validate_string_env_vars() {
    local errors=0

    # Validate WEBSEARCH_ENGINES contains only safe characters
    if [[ ! "$WEBSEARCH_ENGINES" =~ ^[a-zA-Z0-9,_-]+$ ]]; then
        echo -e "${RED}Error:${NC} WEBSEARCH_ENGINES contains invalid characters (got: '$WEBSEARCH_ENGINES')" >&2
        echo -e "${RED}       Only alphanumeric, comma, underscore, and hyphen are allowed${NC}" >&2
        ((errors++))
    fi

    # Validate model names don't contain shell metacharacters
    for model_var in OPENAI_MODEL CLAUDE_MODEL GEMINI_MODEL; do
        model_value="${!model_var}"
        if [ -n "$model_value" ] && [[ ! "$model_value" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
            echo -e "${RED}Error:${NC} ${model_var} contains invalid characters (got: '$model_value')" >&2
            echo -e "${RED}       Only alphanumeric, dot, underscore, slash, and hyphen are allowed${NC}" >&2
            ((errors++))
        fi
    done

    # Validate CHAIRMAN if set
    if [ -n "$CHAIRMAN" ] && [[ ! "$CHAIRMAN" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
        echo -e "${RED}Error:${NC} CHAIRMAN contains invalid characters (got: '$CHAIRMAN')" >&2
        echo -e "${RED}       Only alphanumeric, dot, underscore, slash, and hyphen are allowed${NC}" >&2
        ((errors++))
    fi

    if [ $errors -gt 0 ]; then
        return 1
    fi
    return 0
}

# Extract URLs from query using grep
extract_urls_from_query() {
    local query="$1"
    echo "$query" | grep -oE 'https?://[^[:space:]]+' | sort -u
}

# Fetch content from explicit URLs in the query (with security validation)
fetch_explicit_urls() {
    local query="$1"
    local urls
    urls=$(extract_urls_from_query "$query")

    if [ -z "$urls" ]; then
        return 1  # No URLs found
    fi

    local fetched_content=""
    local url_count=0
    local success_count=0
    local blocked_count=0

    while IFS= read -r url; do
        [ -z "$url" ] && continue
        ((url_count++))

        # Validate URL is safe before fetching (SSRF protection)
        if ! is_safe_url "$url"; then
            echo -e "${RED}  ✗ Blocked unsafe URL: $url${NC}" >&2
            ((blocked_count++))
            continue
        fi

        echo -e "${BLUE}  → Fetching explicit URL: $url${NC}" >&2

        local content
        content=$(fetch_url_content_limited "$url")

        if [ -n "$content" ]; then
            ((success_count++))
            fetched_content="${fetched_content}
=== CONTENT FROM: $url ===
$content
=== END CONTENT ===

"
        else
            echo -e "${YELLOW}    ⚠ Failed to fetch $url${NC}" >&2
        fi
    done <<< "$urls"

    if [ "$blocked_count" -gt 0 ]; then
        echo -e "${YELLOW}  ⚠ Blocked $blocked_count unsafe URL(s) for security reasons${NC}" >&2
    fi

    if [ -n "$fetched_content" ]; then
        echo -e "${GREEN}  ✓ Successfully fetched $success_count of $url_count URL(s)${NC}" >&2
        echo "$fetched_content"
        return 0
    else
        echo -e "${RED}  ✗ Failed to fetch any URLs${NC}" >&2
        return 1
    fi
}

# ============================================================================
# MODEL INVOCATION FUNCTIONS
# ============================================================================

run_openai() {
    local prompt="$1"
    local reasoning="${2:-high}"  # Default to high reasoning since codex is chairman
    local max_tokens="${3:-}"     # Optional max_tokens for OpenAI/Codex

    # Add research context preamble for council queries (not for planning queries)
    # Planning queries use low reasoning, council queries use high reasoning
    if [ "$reasoning" = "high" ] || [ "$reasoning" = "medium" ]; then
        local enhanced_prompt="You are a terminal AI council member conducting independent research.

RESEARCH CONTEXT:
- If web search results appear below, they came from queries YOU formulated during planning.
- Synthesize findings from multiple sources into comprehensive, analytical response.
- Cite specific sources when making factual claims.
- Use your reasoning capability to identify patterns and insights across sources.
- Your research approach may differ from other council members.

User question:
${prompt}"
        prompt="$enhanced_prompt"
    fi

    # Clamp reasoning to supported values for gpt-5.x to avoid 400 errors
    case "$reasoning" in
        none|low|medium|high) ;;
        *) reasoning="high" ;;
    esac

    if [ "$OPENAI_TOOL" = "openai" ]; then
        local payload
        local errfile="$TEMP_DIR/openai_err.log"
        if [ -n "$max_tokens" ]; then
            payload=$(jq -cn --arg prompt "$prompt" --argjson max_tokens "$max_tokens" \
                '{messages:[{role:"user",content:$prompt}], max_tokens: $max_tokens}')
        else
            payload=$(jq -cn --arg prompt "$prompt" \
                '{messages:[{role:"user",content:$prompt}]}')
        fi
        local raw
        if ! raw=$(run_with_timeout "$MODEL_TIMEOUT_SECONDS" openai api chat.completions.create -m "$OPENAI_MODEL" -g "$payload" 2>"$errfile"); then
            echo "OpenAI CLI failed: $(cat "$errfile")" >&2
            return 1
        fi
        local content
        content=$(printf '%s' "$raw" | jq -r '.choices[0].message.content // ""' 2>/dev/null || true)
        if [ -z "$(echo "$content" | tr -d '[:space:]')" ]; then
            echo "OpenAI returned empty output" >&2
            return 1
        fi
        printf '%s\n' "$content"
    else
        # codex CLI path: capture reply via output-last-message with stdout fallback and surface errors
        local tmp_out errfile raw content
        tmp_out=$(mktemp "${TEMP_DIR}/openai_codex_XXXXXX")
        chmod 600 "$tmp_out"  # Restrict access to owner only
        errfile="$TEMP_DIR/openai_err.log"

        local args=(
            -c model="$OPENAI_MODEL"
            -c reasoning_effort="$reasoning"
            --skip-git-repo-check
            -s read-only
            --color never
            --output-last-message "$tmp_out"
        )
        if [ -n "$max_tokens" ]; then
            args+=(-c "max_output_tokens=$max_tokens")
        fi

        if ! raw=$(run_with_timeout "$MODEL_TIMEOUT_SECONDS" codex exec "$prompt" "${args[@]}" 2>"$errfile"); then
            echo "Codex failed: $(cat "$errfile")" >&2
            rm -f "$tmp_out"
            return 1
        fi

        # Prefer the output-last-message file if it has content
        if [ -s "$tmp_out" ]; then
            content=$(cat "$tmp_out")
        else
            # Fallback: extract response from stdout by taking everything after the last occurrence
            # of common codex CLI output patterns (session info, thinking, tokens used, etc.)
            # The actual response typically appears after these verbose lines
            content=$(echo "$raw" | awk '
                /^[a-zA-Z0-9_-]+$/ { next }
                /^(workdir|model|provider|approval|sandbox|reasoning|session id):/ { next }
                /^thinking$/ { next }
                /^tokens used$/ { next }
                /^[0-9,]+$/ { next }
                /^--------$/ { next }
                /^OpenAI Codex/ { next }
                { print }
            ')
        fi
        rm -f "$tmp_out"

        if [ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ]; then
            echo "Codex returned empty output (no text in last-message file or stdout)" >&2
            return 1
        fi
        printf '%s\n' "$content"
    fi
}

run_claude() {
    local prompt="$1"
    local constrained_prompt="You are one member of a terminal LLM council providing expert analysis and responses.

CRITICAL INSTRUCTIONS:
- You MAY use available MCP tools (web search, etc.) when helpful for research.
- You MUST provide complete, direct answers - do NOT ask for permission or say \"Would you like me to...\"
- Do NOT stay at a meta-level describing what you would do - actually do it and show the result.
- If asked to create content (prompts, code, documentation), provide the complete content directly in your response.
- Do NOT say you need permission to write files - instead, present the complete content that should be written.
- Your response will be reviewed by other models, so make it substantive and complete.

RESEARCH CONTEXT:
- If web search results appear below, they came from queries YOU formulated during planning.
- Synthesize findings from multiple sources into your analysis.
- Cite specific sources when making factual claims.
- Note gaps where search results didn't provide sufficient information.
- Your independent research strategy may differ from other council members.

User request:
${prompt}"

    # Note: --max-tokens not reliably supported across all versions
    local out
    if ! out=$(printf '%s' "$constrained_prompt" | run_with_timeout "$MODEL_TIMEOUT_SECONDS" claude --print --output-format text --model "$CLAUDE_MODEL"); then
        echo "Claude failed" >&2
        return 1
    fi
    if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
        echo "Claude returned empty output" >&2
        return 1
    fi
    printf '%s\n' "$out"
}

run_gemini() {
    local prompt="$1"
    local constrained_prompt="You are one member of a terminal LLM council specializing in research synthesis.

CRITICAL CONSTRAINTS:
- You have NO access to tools, MCP servers, shell commands, or the filesystem during execution.
- Do NOT say you will use tools like read_file, write_file, replace, apply_patch, run_shell_command, or similar.
- Do NOT narrate steps like \"I will now run a command\" or \"I will use tool X\".
- If changes to files are needed, describe the exact edits or final file contents in plain language for a human to apply.

RESEARCH SYNTHESIS APPROACH:
- If web search results appear below, they came from queries you independently formulated during planning.
- Synthesize findings into a comprehensive, well-cited answer.
- Cross-reference multiple sources to validate claims.
- Identify contradictions or gaps in the research.
- Present your analysis in clear, structured markdown.
- Your research strategy may differ from other council members.

Always respond with a single, self-contained markdown answer addressed to a human operator.

User request:
${prompt}"

    local errfile="$TEMP_DIR/gemini_err.log"

    # Use positional prompt form to match Gemini CLI non-interactive contract; keep plain-text output.
    local out
    if ! out=$(run_with_timeout "$MODEL_TIMEOUT_SECONDS" gemini --output-format text --model "$GEMINI_MODEL" "$constrained_prompt" 2>"$errfile"); then
        echo "Gemini failed: $(cat "$errfile")" >&2
        return 1
    fi

    # Strip ANSI/control codes before checking emptiness to catch control-only output.
    local clean_out
    clean_out=$(printf '%s' "$out" | perl -pe 's/\e\[[0-?]*[ -\/]*[@-~]//g')

    if [ -z "$(printf '%s' "$clean_out" | tr -d '[:space:]')" ]; then
        echo "Gemini returned empty output" >&2
        return 1
    fi

    printf '%s\n' "$clean_out"
}

invoke_model() {
    local model="$1"
    local prompt="$2"
    # Optional max_tokens: enforced for OpenAI/Codex, ignored by Claude/Gemini
    local max_tokens="${3:-}"
    local response

    # Get response from model
    case "$model" in
        openai)
            if [ -n "$max_tokens" ]; then
                response=$(run_openai "$prompt" "high" "$max_tokens")
            else
                response=$(run_openai "$prompt" "high")
            fi
            ;;
        claude)
            response=$(run_claude "$prompt")
            ;;
        gemini)
            response=$(run_gemini "$prompt")
            ;;
        *) echo "Unknown model: $model" >&2; exit 1 ;;
    esac

    # Return response only (tracking happens outside to avoid subshell variable loss)
    echo "$response"
}

build_review_prompt() {
    local question="$1"
    local peer_response="$2"
    cat <<EOF
You are reviewing a peer AI's response to the question:
"$question"

Peer response:
<<<
$peer_response
>>>

Provide a concise critique in 2-3 sentences that covers accuracy, completeness, and clarity.
Finish with "Rating: X/5".
EOF
}

# Helper to get token stats for a model (bash 3.2 compatible)
get_model_tokens() {
    local model="$1"
    local stat_type="$2"  # input, output, or total

    case "$model" in
        openai)
            case "$stat_type" in
                input) echo "$OPENAI_INPUT_TOKENS" ;;
                output) echo "$OPENAI_OUTPUT_TOKENS" ;;
                total) echo "$OPENAI_TOTAL_TOKENS" ;;
            esac
            ;;
        claude)
            case "$stat_type" in
                input) echo "$CLAUDE_INPUT_TOKENS" ;;
                output) echo "$CLAUDE_OUTPUT_TOKENS" ;;
                total) echo "$CLAUDE_TOTAL_TOKENS" ;;
            esac
            ;;
        gemini)
            case "$stat_type" in
                input) echo "$GEMINI_INPUT_TOKENS" ;;
                output) echo "$GEMINI_OUTPUT_TOKENS" ;;
                total) echo "$GEMINI_TOTAL_TOKENS" ;;
            esac
            ;;
        *) echo "0" ;;
    esac
}

print_token_report() {
    echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}TOKEN USAGE REPORT${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

    # Per-model breakdown
    echo -e "${BOLD}${YELLOW}Per-Model Token Usage:${NC}"
    for model in "${MODEL_IDS[@]}"; do
        local label
        local input
        local output
        local total
        label=$(get_model_label "$model")
        input=$(get_model_tokens "$model" "input")
        output=$(get_model_tokens "$model" "output")
        total=$(get_model_tokens "$model" "total")

        printf "  ${GREEN}%-45s${NC}\n" "$label"
        printf "    Input:  %10d tokens\n" "$input"
        printf "    Output: %10d tokens\n" "$output"
        printf "    ${BOLD}Total:  %10d tokens${NC}\n" "$total"
        echo ""
    done

    # Chairman if different from council
    local chairman_used=false
    for model in "${MODEL_IDS[@]}"; do
        if [ "$model" = "$CHAIRMAN" ]; then
            chairman_used=true
            break
        fi
    done

    if [ "$chairman_used" = false ]; then
        local label
        local input
        local output
        local total
        label=$(get_model_label "$CHAIRMAN")
        input=$(get_model_tokens "$CHAIRMAN" "input")
        output=$(get_model_tokens "$CHAIRMAN" "output")
        total=$(get_model_tokens "$CHAIRMAN" "total")

        printf "  ${GREEN}%-45s${NC} (Chairman only)\n" "$label"
        printf "    Input:  %10d tokens\n" "$input"
        printf "    Output: %10d tokens\n" "$output"
        printf "    ${BOLD}Total:  %10d tokens${NC}\n" "$total"
        echo ""
    fi

    # Global totals
    local grand_total=$(( TOTAL_INPUT_TOKENS + TOTAL_OUTPUT_TOKENS ))
    echo -e "${BOLD}${MAGENTA}Overall Token Usage:${NC}"
    printf "  Total Input:  %10d tokens\n" "$TOTAL_INPUT_TOKENS"
    printf "  Total Output: %10d tokens\n" "$TOTAL_OUTPUT_TOKENS"
    printf "  ${BOLD}Grand Total:  %10d tokens${NC}\n" "$grand_total"
    echo ""
    echo -e "${CYAN}Note: Token counts are estimated based on character count (1 token ≈ 4 chars)${NC}"
    echo -e "${CYAN}Actual usage may vary depending on the model's tokenizer.${NC}"
    echo ""
}

ensure_chairman() {
    if ! model_exists "$CHAIRMAN"; then
        echo -e "${YELLOW}Warning:${NC} Unknown CHAIRMAN '$CHAIRMAN'. Falling back to 'gemini'."
        CHAIRMAN="gemini"
    fi
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

# Check if query is provided
if [ $# -eq 0 ]; then
    echo -e "${RED}Error: No query provided${NC}"
    echo "Usage: $0 \"Your question here\""
    exit 1
fi

QUERY="$*"

# Validate required commands
require_command "gemini"
require_command "claude"
require_command "jq"
require_command "curl"
require_command "perl"

# Validate configuration
if ! validate_numeric_env_vars; then
    echo -e "${RED}Configuration validation failed. Please check your environment variables.${NC}"
    exit 1
fi

if ! validate_string_env_vars; then
    echo -e "${RED}String environment variable validation failed. Please check your model names and settings.${NC}"
    exit 1
fi

# Warn if timeout command is unavailable (performance/reliability impact)
if [ -z "$TIMEOUT_CMD" ]; then
    echo -e "${YELLOW}Warning:${NC} 'timeout' command not found - model calls will run without timeout protection" >&2
    echo -e "${YELLOW}         This may cause the script to hang if a model becomes unresponsive${NC}" >&2
    echo -e "${YELLOW}         Install 'timeout' (part of GNU coreutils) for better reliability${NC}" >&2
    echo ""
fi

validate_websearch_url

if command -v openai >/dev/null 2>&1; then
    OPENAI_TOOL="openai"
    OPENAI_DISPLAY="OpenAI CLI (${OPENAI_MODEL})"
elif command -v codex >/dev/null 2>&1; then
    OPENAI_TOOL="codex"
    OPENAI_DISPLAY="Codex CLI (${OPENAI_MODEL} - High Reasoning)"
else
    echo -e "${RED}Error:${NC} Neither 'openai' nor 'codex' CLI was found."
    exit 1
fi

ensure_chairman
CHAIRMAN_LABEL=$(get_model_label "$CHAIRMAN")

echo -e "${BOLD}${MAGENTA}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║            TERMINAL LLM COUNCIL (with Web Search)             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Prevent terminal control injection by not using -e with user input
echo -e "${YELLOW}Your Question:${NC}"
printf ' %s\n\n' "$QUERY"

# ============================================================================
# STAGE 1: Collect Individual Responses (with independent web search)
# ============================================================================

print_header "STAGE 1: COLLECTING INDIVIDUAL RESPONSES"

# Check if web search should be performed for this query
ENABLE_WEB_SEARCH_FOR_QUERY=false
EXPLICIT_URLS_CONTENT=""

# First, check if query contains explicit URLs and fetch them directly
if check_websearch_server; then
    # Temporarily disable set -e to capture exit code without exiting script
    set +e
    # Only capture stdout (content), let stderr (logs) go to terminal
    EXPLICIT_URLS_CONTENT=$(fetch_explicit_urls "$QUERY")
    fetch_exit_code=$?
    set -e

    if [ $fetch_exit_code -eq 0 ] && [ -n "$EXPLICIT_URLS_CONTENT" ]; then
        ENABLE_WEB_SEARCH_FOR_QUERY=true
        echo -e "${CYAN}Explicit URLs detected and fetched - content will be provided to all models${NC}\n"
    fi
fi

# Then, check if additional web search is needed
if [ "$ENABLE_WEB_SEARCH_FOR_QUERY" = false ] && check_websearch_server && needs_web_search "$QUERY"; then
    ENABLE_WEB_SEARCH_FOR_QUERY=true
    echo -e "${CYAN}Web search enabled - each model will perform independent research${NC}\n"
fi

# Run Stage 1 queries in parallel for better performance
stage1_pids=()
for model in "${MODEL_IDS[@]}"; do
    (
        # All work for this model happens in this subshell (runs in background)
        label=$(get_model_label "$model")
        echo -e "${BLUE}Querying ${label}...${NC}"

        # Perform independent web search for this model
        if [ "$ENABLE_WEB_SEARCH_FOR_QUERY" = true ]; then
        echo -e "${BLUE}  → Planning independent research for ${label}...${NC}"

        # Generate model-specific search queries
        model_queries=()
        while IFS= read -r line; do
            model_queries+=("$line")
        done < <(generate_search_queries_for_model "$model" "$QUERY" 5)
        if [ "$COUNCIL_DEBUG" = "true" ]; then
            debug_log "Planned queries for ${label}:"
            for q in "${model_queries[@]}"; do
                debug_log "  - $q"
            done
        fi

        echo -e "${GREEN}  ✓ Generated ${#model_queries[@]} search queries${NC}"

        # Execute each query and aggregate results with deduplication
        model_search_results_text=""
        fetched_content=""
        seen_urls=""  # Space-separated list of URLs for deduplication (Bash 3.2 compatible)

        for query in "${model_queries[@]}"; do
            echo -e "${BLUE}    → Searching: ${query}${NC}"
            query_start=$SECONDS

            # Graceful degradation: continue even if search fails
            set +e
            query_results=$(web_search_json "$query" 3)  # 3 results per query
            search_exit_code=$?
            set -e

            if [ "$COUNCIL_DEBUG" = "true" ]; then
                debug_log "Search completed for ${label} query in $((SECONDS - query_start))s (exit code: $search_exit_code)"
            fi

            # Skip if search failed
            if [ $search_exit_code -ne 0 ]; then
                debug_log "Skipping failed search query for ${label}"
                continue
            fi

            # Aggregate results (deduplicating URLs)
            if [ -n "$query_results" ] && [ "$(echo "$query_results" | jq '.results | length')" -gt 0 ]; then
                # Extract and format results, tracking URLs
                # Performance: single jq call extracts all three fields at once
                while IFS=$'\t' read -r url title desc; do
                    # Only add if we haven't seen this URL yet (Bash 3.2 compatible string-based dedup)
                    if ! echo " $seen_urls " | grep -Fq " $url "; then
                        seen_urls="$seen_urls $url"
                        model_search_results_text="${model_search_results_text}Title: ${title}
URL: ${url}
Description: ${desc}
---
"
                    fi
                done < <(echo "$query_results" | jq -r '.results[] | [.url, .title, .description] | @tsv')
            fi
        done

        if [ -n "$model_search_results_text" ]; then
            # Count unique URLs (Bash 3.2 compatible - count words in string)
            unique_url_count=$(echo "$seen_urls" | wc -w | tr -d ' ')
            echo -e "${GREEN}  ✓ Search completed with $unique_url_count unique results${NC}"
            debug_log "Dedup for ${label}: $unique_url_count unique URLs"

            # Optionally fetch main content from top URLs
            fetch_url_enable_lower=$(echo "$FETCH_URL_ENABLE" | tr '[:upper:]' '[:lower:]')
            if [ "$fetch_url_enable_lower" = "true" ]; then
                echo -e "${BLUE}  → Fetching content from top URL(s)...${NC}"
                fetch_count=0
                # Fetch from our deduplicated URLs (Bash 3.2 compatible - convert string to array)
                IFS=' ' read -ra url_array <<< "$seen_urls"
                for url in "${url_array[@]}"; do
                    [ -z "$url" ] && continue

                    # Validate URL is safe before fetching (SSRF protection)
                    if ! is_safe_url "$url"; then
                        echo -e "${RED}    ✗ Blocked unsafe URL from search results: $url${NC}" >&2
                        continue
                    fi

                    ((fetch_count++))
                    echo -e "${BLUE}    → Fetching: $url${NC}"
                    content=$(fetch_url_content_limited "$url")
                    if [ -n "$content" ]; then
                        fetched_content="${fetched_content}

--- CONTENT FROM: $url ---
$content
--- END CONTENT ---
"
                    else
                        echo -e "${YELLOW}    ⚠ No content returned for $url${NC}"
                    fi
                    [ "$fetch_count" -ge "$FETCH_URL_RESULTS" ] && break
                done
            fi

            # Save search results and fetched content for session documentation
            printf '%s\n' "$model_search_results_text" >"$TEMP_DIR/${model}_search_results.txt"
            if [ -n "$fetched_content" ]; then
                printf '%s\n' "$fetched_content" >"$TEMP_DIR/${model}_fetched_content.txt"
            fi
            # Save explicit URLs content if available (shared across all models)
            if [ -n "$EXPLICIT_URLS_CONTENT" ] && [ ! -f "$TEMP_DIR/explicit_urls_content.txt" ]; then
                printf '%s\n' "$EXPLICIT_URLS_CONTENT" >"$TEMP_DIR/explicit_urls_content.txt"
            fi

            # Create model-specific context with both search results and fetched content (if any)
            model_context="
$( [ -n "$EXPLICIT_URLS_CONTENT" ] && cat <<'EOF'

=== EXPLICIT URL CONTENT ===
The following content was fetched directly from URLs in your query:
EOF
)
$( [ -n "$EXPLICIT_URLS_CONTENT" ] && echo "$EXPLICIT_URLS_CONTENT" )
$( [ -n "$EXPLICIT_URLS_CONTENT" ] && echo "=== END EXPLICIT URL CONTENT ===" )

=== WEB SEARCH RESULTS FOR YOUR ANALYSIS ===
The following web search results may help you answer the question:

$model_search_results_text

=== END WEB SEARCH RESULTS ===

$( [ -n "$fetched_content" ] && cat <<'EOF'
=== FETCHED WEB CONTENT ===
Below is the actual content retrieved from the URLs above:
EOF
)
$fetched_content
$( [ -n "$fetched_content" ] && echo "=== END FETCHED CONTENT ===" )

"
            enhanced_query="${model_context}${QUERY}"
        else
            echo -e "${YELLOW}  ⚠ No search results found${NC}"
            # Still include explicit URLs content even if search failed
            if [ -n "$EXPLICIT_URLS_CONTENT" ]; then
                model_context="

=== EXPLICIT URL CONTENT ===
The following content was fetched directly from URLs in your query:

$EXPLICIT_URLS_CONTENT

=== END EXPLICIT URL CONTENT ===

"
                enhanced_query="${model_context}${QUERY}"
            else
                enhanced_query="$QUERY"
            fi
        fi
    else
        # No web search, but still include explicit URLs if available
        if [ -n "$EXPLICIT_URLS_CONTENT" ]; then
            model_context="

=== EXPLICIT URL CONTENT ===
The following content was fetched directly from URLs in your query:

$EXPLICIT_URLS_CONTENT

=== END EXPLICIT URL CONTENT ===

"
            enhanced_query="${model_context}${QUERY}"
        else
            enhanced_query="$QUERY"
        fi
    fi

        response=$(invoke_model "$model" "$enhanced_query" "$MAX_TOKENS_STAGE1")
        printf '%s\n' "$response" >"$TEMP_DIR/${model}_response.txt"

        # Save enhanced query and estimated tokens for later display
        printf '%s\n' "$enhanced_query" >"$TEMP_DIR/${model}_enhanced_query.txt"
    ) &
    stage1_pids+=($!)
done

# Wait for all Stage 1 model queries to complete
echo -e "\n${YELLOW}Waiting for all models to complete...${NC}"
wait

# Display results and track tokens (sequential, after parallel execution)
echo ""
for model in "${MODEL_IDS[@]}"; do
    label=$(get_model_label "$model")
    response=$(cat "$TEMP_DIR/${model}_response.txt")
    enhanced_query=$(cat "$TEMP_DIR/${model}_enhanced_query.txt")

    # Track tokens for this model
    input_tokens=$(estimate_tokens "$enhanced_query")
    output_tokens=$(estimate_tokens "$response")
    track_tokens "$model" "$input_tokens" "$output_tokens"

    # Display response
    print_model "$label"
    printf '%s\n\n' "$response"
done

# ============================================================================
# STAGE 2: Peer Review
# ============================================================================

print_header "STAGE 2: PEER REVIEW"

# Run peer reviews in parallel for better performance
stage2_pids=()
for reviewer in "${MODEL_IDS[@]}"; do
    for reviewee in "${MODEL_IDS[@]}"; do
        if [ "$reviewer" = "$reviewee" ]; then
            continue
        fi
        (
            # All work for this review happens in this subshell (runs in background)
            reviewer_label=$(get_model_label "$reviewer")
            reviewee_label=$(get_model_label "$reviewee")
            reviewee_response=$(cat "$TEMP_DIR/${reviewee}_response.txt")
            review_prompt=$(build_review_prompt "$QUERY" "$reviewee_response")
            echo -e "${BLUE}${reviewer_label} reviewing ${reviewee_label}...${NC}"
            review=$(invoke_model "$reviewer" "$review_prompt" "$MAX_TOKENS_STAGE2")
            printf '%s\n' "$review" >"$TEMP_DIR/review_${reviewer}_${reviewee}.txt"

            # Save review prompt for later token tracking
            printf '%s\n' "$review_prompt" >"$TEMP_DIR/review_prompt_${reviewer}_${reviewee}.txt"
        ) &
        stage2_pids+=($!)
    done
done

# Wait for all Stage 2 peer reviews to complete
echo -e "\n${YELLOW}Waiting for all peer reviews to complete...${NC}"
wait

# Display results and track tokens (sequential, after parallel execution)
echo ""
for reviewer in "${MODEL_IDS[@]}"; do
    for reviewee in "${MODEL_IDS[@]}"; do
        if [ "$reviewer" = "$reviewee" ]; then
            continue
        fi
        reviewer_label=$(get_model_label "$reviewer")
        reviewee_label=$(get_model_label "$reviewee")
        review=$(cat "$TEMP_DIR/review_${reviewer}_${reviewee}.txt")
        review_prompt=$(cat "$TEMP_DIR/review_prompt_${reviewer}_${reviewee}.txt")

        # Track tokens for this review
        input_tokens=$(estimate_tokens "$review_prompt")
        output_tokens=$(estimate_tokens "$review")
        track_tokens "$reviewer" "$input_tokens" "$output_tokens"

        # Display review
        print_model "${reviewer_label} → ${reviewee_label}"
        printf '%s\n\n' "$review"
    done
done

# ============================================================================
# STAGE 3: Final Synthesis
# ============================================================================

print_header "STAGE 3: FINAL SYNTHESIS"

SYNTH_PROMPT_FILE="$TEMP_DIR/synthesis_prompt.txt"
{
    echo "You are the Chairman of an AI council."
    echo "Question: $QUERY"

    if [ "$ENABLE_WEB_SEARCH_FOR_QUERY" = true ]; then
        echo ""
        echo "NOTE: Each council member independently performed their own web research when forming their responses."
    fi

    echo ""
    for model in "${MODEL_IDS[@]}"; do
        label=$(get_model_label "$model")
        echo "Model: $label"
        echo "Response:"
        sed 's/^/    /' "$TEMP_DIR/${model}_response.txt"
        echo ""
        echo "Peer feedback on $label:"
        for reviewer in "${MODEL_IDS[@]}"; do
            if [ "$reviewer" = "$model" ]; then
                continue
            fi
            review_path="$TEMP_DIR/review_${reviewer}_${model}.txt"
            reviewer_label=$(get_model_label "$reviewer")
            if [ -s "$review_path" ]; then
                echo "- ${reviewer_label}:"
                sed 's/^/    /' "$review_path"
            else
                echo "- ${reviewer_label}: (no review captured)"
            fi
            echo ""
        done
        echo ""
    done
    echo "Produce a concise but thorough final answer that blends the strongest insights."
    echo "Note consensus, highlight disagreements, and cite which model contributed key points."
} >"$SYNTH_PROMPT_FILE"

echo -e "${BLUE}${CHAIRMAN_LABEL} synthesizing final response...${NC}\n"
SYNTHESIS_PROMPT=$(cat "$SYNTH_PROMPT_FILE")
FINAL_RESPONSE=$(invoke_model "$CHAIRMAN" "$SYNTHESIS_PROMPT" "$MAX_TOKENS_STAGE3")

# Track tokens for synthesis
input_tokens=$(estimate_tokens "$SYNTHESIS_PROMPT")
output_tokens=$(estimate_tokens "$FINAL_RESPONSE")
track_tokens "$CHAIRMAN" "$input_tokens" "$output_tokens"

echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║                      FINAL ANSWER                              ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}\n"

printf '%s\n\n' "$FINAL_RESPONSE"

# Display token usage report
print_token_report

print_header "COUNCIL SESSION COMPLETE"

COUNCIL_SUMMARY=""
for model in "${MODEL_IDS[@]}"; do
    label=$(get_model_label "$model")
    if [ -z "$COUNCIL_SUMMARY" ]; then
        COUNCIL_SUMMARY="$label"
    else
        COUNCIL_SUMMARY="$COUNCIL_SUMMARY, $label"
    fi
done

echo -e "${CYAN}Summary:${NC}"
echo "  • Council Members: $COUNCIL_SUMMARY"
echo "  • Chairman: $CHAIRMAN_LABEL"
if [ "$ENABLE_WEB_SEARCH_FOR_QUERY" = true ]; then
    echo "  • Web Research: Enabled - Each model performed independent research (via ${WEBSEARCH_URL})"
    echo "  • Research Depth: Fetching up to ${FETCH_URL_RESULTS} URLs with ${FETCH_URL_MAX_CHARS} chars each"
else
    echo "  • Web Research: Disabled or unavailable"
fi
echo "  • Stages Completed: Independent Research → Response Collection → Peer Review → Synthesis"
echo "  • Responses saved in: $TEMP_DIR"
echo ""

# Save session documentation (unless disabled)
if [ "${COUNCIL_SAVE_SESSION:-true}" = "true" ]; then
    echo -e "${BLUE}Saving session documentation...${NC}"
    SESSION_FILE=$(save_session_documentation)
    echo -e "${GREEN}✓ Session saved to: ${SESSION_FILE}${NC}"
    echo ""
else
    echo -e "${YELLOW}⚠ Session logging disabled (COUNCIL_SAVE_SESSION=false)${NC}"
    echo ""
fi

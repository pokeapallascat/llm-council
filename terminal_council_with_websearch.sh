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

# Default configuration (overridable via env vars)
OPENAI_MODEL=${OPENAI_MODEL:-"gpt-5.1"}
CLAUDE_MODEL=${CLAUDE_MODEL:-"sonnet"}
GEMINI_MODEL=${GEMINI_MODEL:-"gemini-2.5-pro"}
MODEL_IDS=("openai" "claude" "gemini")
CHAIRMAN=${CHAIRMAN:-"openai"}
OPENAI_TOOL=""
OPENAI_DISPLAY=""

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
trap 'rm -rf "$TEMP_DIR"' EXIT

print_header() {
    echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}$1${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_model() {
    echo -e "${BOLD}${GREEN}[$1]${NC}"
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
    local title_prompt="Summarize this question into a short file title (max 20 characters, lowercase, use underscores instead of spaces, no special characters). Only respond with the title, nothing else.

Question: $query"

    # Call Codex with minimal tokens for quick response
    local short_title
    short_title=$(run_openai "$title_prompt" "low" "50" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//' | cut -c1-20)

    # Fallback if Codex fails or returns empty
    if [ -z "$short_title" ]; then
        short_title=$(echo "$query" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | cut -c1-20 | sed 's/_$//')
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

    # Check for existing files with same date and title to determine version
    local base_pattern="${date_only}_${short_title}"
    local version=""
    local version_num=1

    # Find highest existing version
    for existing_file in "${sessions_dir}/"*"${base_pattern}.md"; do
        if [ -f "$existing_file" ]; then
            # Check if it's a versioned file (v2_, v3_, etc.)
            if [[ "$(basename "$existing_file")" =~ ^v([0-9]+)_ ]]; then
                local found_version="${BASH_REMATCH[1]}"
                if [ "$found_version" -ge "$version_num" ]; then
                    version_num=$((found_version + 1))
                fi
            else
                # Found unversioned file, next should be v2
                version_num=2
            fi
        fi
    done

    # Add version prefix if this is a repeat run
    if [ "$version_num" -gt 1 ]; then
        version="v${version_num}_"
    fi

    local filename="${sessions_dir}/${version}${date_only}_${short_title}.md"

    {
        echo "# Council Session: $QUERY"
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
                cat "$search_file"
                echo '```'
                echo ""
            fi

            if [ -f "$content_file" ] && [ -s "$content_file" ]; then
                echo "**Full Content Fetched:**"
                echo '```'
                cat "$content_file"
                echo '```'
                echo ""
            fi

            echo "#### Response"
            echo ""
            cat "$TEMP_DIR/${model}_response.txt"
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
                    cat "$review_path"
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
        printf '%s\n' "$FINAL_RESPONSE"
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

    if curl -s -f "${WEBSEARCH_URL}/api/health" >/dev/null 2>&1; then
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

    curl -s -X POST "${WEBSEARCH_URL}/api/search" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        | jq -r '.results[] | "Title: \(.title)\nURL: \(.url)\nDescription: \(.description)\n---"' 2>/dev/null || echo ""
}

# Perform web search and return raw JSON results
web_search_json() {
    local query="$1"
    local limit="${2:-5}"
    local payload

    payload=$(jq -nc \
        --arg query "$query" \
        --argjson limit "$limit" \
        --arg engines "$WEBSEARCH_ENGINES" \
        '{query: $query, limit: $limit,
          engines: ($engines | split(",") | map(gsub("^\\s+|\\s+$"; "")))}')

    curl -s -X POST "${WEBSEARCH_URL}/api/search" \
        -H "Content-Type: application/json" \
        -d "$payload"
}

# Fetch content from a specific URL
fetch_url_content() {
    local url="$1"
    local payload

    payload=$(jq -nc --arg url "$url" '{url: $url, useBrowserFallback: true}')

    curl -s -X POST "${WEBSEARCH_URL}/api/fetchUrl" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        | jq -r '.content' 2>/dev/null || echo ""
}

# Fetch content with truncation
fetch_url_content_limited() {
    local url="$1"
    local payload

    payload=$(jq -nc --arg url "$url" --argjson maxLen "$FETCH_URL_MAX_CHARS" '{url: $url, useBrowserFallback: true, maxContentLength: $maxLen}')

    curl -s -X POST "${WEBSEARCH_URL}/api/fetchUrl" \
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

    # Otherwise, ask GPT-5.1 for a decision (prefer higher reasoning for routing)
    local decision_prompt="Does this question require current/recent web information to answer accurately? Answer only YES or NO.

Question: $query"

    local decision
    if [ -n "${OPENAI_TOOL:-}" ]; then
        # Use a small token budget for this quick routing decision
        decision=$(run_openai "$decision_prompt" "high" 128 2>/dev/null | tr '[:lower:]' '[:upper:]')
    else
        decision=$(printf '%s' "$decision_prompt" | gemini --output-format text 2>/dev/null | tr '[:lower:]' '[:upper:]')
    fi

    if [[ "$decision" == *"YES"* ]]; then
        return 0
    else
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
        if ! raw=$(openai api chat.completions.create -m "$OPENAI_MODEL" -g "$payload" 2>"$errfile"); then
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

        if ! raw=$(codex exec "$prompt" "${args[@]}" 2>"$errfile"); then
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

User request:
${prompt}"

    # Note: --max-tokens not reliably supported across all versions
    printf '%s' "$constrained_prompt" | claude --print --output-format text --model "$CLAUDE_MODEL"
}

run_gemini() {
    local prompt="$1"
    local constrained_prompt="You are one member of a terminal LLM council, running in a non-interactive, text-only script.

CRITICAL CONSTRAINTS:
- You have NO access to tools, MCP servers, shell commands, or the filesystem.
- Do NOT say you will use tools like read_file, write_file, replace, apply_patch, run_shell_command, or similar.
- Do NOT narrate steps like \"I will now run a command\" or \"I will use tool X\".
- If changes to files are needed, describe the exact edits or final file contents in plain language for a human to apply.

Always respond with a single, self-contained markdown answer addressed to a human operator.

User request:
${prompt}"

    local errfile="$TEMP_DIR/gemini_err.log"

    # Use positional prompt form to match Gemini CLI non-interactive contract; keep plain-text output.
    local out
    if ! out=$(gemini --output-format text --model "$GEMINI_MODEL" "$constrained_prompt" 2>"$errfile"); then
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

require_command "gemini"
require_command "claude"
require_command "jq"
require_command "curl"

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

echo -e "${YELLOW}Your Question:${NC} $QUERY\n"

# ============================================================================
# STAGE 1: Collect Individual Responses (with independent web search)
# ============================================================================

print_header "STAGE 1: COLLECTING INDIVIDUAL RESPONSES"

# Check if web search should be performed for this query
ENABLE_WEB_SEARCH_FOR_QUERY=false
if check_websearch_server && needs_web_search "$QUERY"; then
    ENABLE_WEB_SEARCH_FOR_QUERY=true
    echo -e "${CYAN}Web search enabled - each model will perform independent research${NC}\n"
fi

for model in "${MODEL_IDS[@]}"; do
    label=$(get_model_label "$model")
    echo -e "${BLUE}Querying ${label}...${NC}"

    # Perform independent web search for this model
    if [ "$ENABLE_WEB_SEARCH_FOR_QUERY" = true ]; then
        echo -e "${BLUE}  → Performing independent web search for ${label}...${NC}"
        model_search_json=$(web_search_json "$QUERY" 5)
        model_search_results_text=""
        fetched_content=""

        if [ -n "$model_search_json" ] && [ "$(echo "$model_search_json" | jq '.results | length')" -gt 0 ]; then
            echo -e "${GREEN}  ✓ Search completed${NC}"
            model_search_results_text=$(echo "$model_search_json" \
                | jq -r '.results[] | "Title: \(.title)\nURL: \(.url)\nDescription: \(.description)\n---"')

            # Optionally fetch main content from top URLs
            fetch_url_enable_lower=$(echo "$FETCH_URL_ENABLE" | tr '[:upper:]' '[:lower:]')
            if [ "$fetch_url_enable_lower" = "true" ]; then
                echo -e "${BLUE}  → Fetching content from top URL(s)...${NC}"
                fetch_count=0
                while IFS= read -r url; do
                    [ -z "$url" ] && continue
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
                done < <(echo "$model_search_json" | jq -r '.results[].url')
            fi

            # Save search results and fetched content for session documentation
            printf '%s\n' "$model_search_results_text" >"$TEMP_DIR/${model}_search_results.txt"
            if [ -n "$fetched_content" ]; then
                printf '%s\n' "$fetched_content" >"$TEMP_DIR/${model}_fetched_content.txt"
            fi

            # Create model-specific context with both search results and fetched content (if any)
            model_context="

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
            enhanced_query="$QUERY"
        fi
    else
        enhanced_query="$QUERY"
    fi

    response=$(invoke_model "$model" "$enhanced_query" "$MAX_TOKENS_STAGE1")
    printf '%s\n' "$response" >"$TEMP_DIR/${model}_response.txt"

    # Track tokens for this model (must be outside subshell)
    input_tokens=$(estimate_tokens "$enhanced_query")
    output_tokens=$(estimate_tokens "$response")
    track_tokens "$model" "$input_tokens" "$output_tokens"

    print_model "$label"
    printf '%s\n\n' "$response"
done

# ============================================================================
# STAGE 2: Peer Review
# ============================================================================

print_header "STAGE 2: PEER REVIEW"

for reviewer in "${MODEL_IDS[@]}"; do
    for reviewee in "${MODEL_IDS[@]}"; do
        if [ "$reviewer" = "$reviewee" ]; then
            continue
        fi
        reviewer_label=$(get_model_label "$reviewer")
        reviewee_label=$(get_model_label "$reviewee")
        reviewee_response=$(cat "$TEMP_DIR/${reviewee}_response.txt")
        review_prompt=$(build_review_prompt "$QUERY" "$reviewee_response")
        echo -e "${BLUE}${reviewer_label} reviewing ${reviewee_label}...${NC}"
        review=$(invoke_model "$reviewer" "$review_prompt" "$MAX_TOKENS_STAGE2")
        printf '%s\n' "$review" >"$TEMP_DIR/review_${reviewer}_${reviewee}.txt"

        # Track tokens for this review
        input_tokens=$(estimate_tokens "$review_prompt")
        output_tokens=$(estimate_tokens "$review")
        track_tokens "$reviewer" "$input_tokens" "$output_tokens"

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

# Save session documentation
echo -e "${BLUE}Saving session documentation...${NC}"
SESSION_FILE=$(save_session_documentation)
echo -e "${GREEN}✓ Session saved to: ${SESSION_FILE}${NC}"
echo ""

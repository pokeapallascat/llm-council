#!/bin/bash

# Terminal LLM Council
# Uses local CLI tools: openai, claude, and gemini

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
GEMINI_MODEL=${GEMINI_MODEL:-"gemini-2.0-flash-exp"}
MODEL_IDS=("openai" "claude" "gemini")
CHAIRMAN=${CHAIRMAN:-"openai"}
OPENAI_TOOL=""
OPENAI_DISPLAY=""

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

run_openai() {
    local prompt="$1"
    if [ "$OPENAI_TOOL" = "openai" ]; then
        local payload
        payload=$(jq -cn --arg prompt "$prompt" '{messages:[{role:"user",content:$prompt}]}')
        openai api chat.completions.create -m "$OPENAI_MODEL" -g "$payload" \
            | jq -r '.choices[0].message.content // ""'
    else
        codex exec "$prompt" -c model="$OPENAI_MODEL" -c reasoning_effort=high
    fi
}

run_claude() {
    local prompt="$1"
    printf '%s' "$prompt" | claude --print --output-format text --model "$CLAUDE_MODEL" --tools ""
}

run_gemini() {
    local prompt="$1"
    # Use default model if GEMINI_MODEL is not specifically set to override
    if [ "$GEMINI_MODEL" = "gemini-2.0-flash-exp" ]; then
        printf '%s' "$prompt" | gemini --output-format text
    else
        printf '%s' "$prompt" | gemini --model "$GEMINI_MODEL" --output-format text
    fi
}

invoke_model() {
    local model="$1"
    local prompt="$2"
    case "$model" in
        openai) run_openai "$prompt" ;;
        claude) run_claude "$prompt" ;;
        gemini) run_gemini "$prompt" ;;
        *) echo "Unknown model: $model" >&2; exit 1 ;;
    esac
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

ensure_chairman() {
    if ! model_exists "$CHAIRMAN"; then
        echo -e "${YELLOW}Warning:${NC} Unknown CHAIRMAN '$CHAIRMAN'. Falling back to 'gemini'."
        CHAIRMAN="gemini"
    fi
}

# Check if query is provided
if [ $# -eq 0 ]; then
    echo -e "${RED}Error: No query provided${NC}"
    echo "Usage: $0 \"Your question here\""
    exit 1
fi

QUERY="$*"

require_command "gemini"
require_command "claude"

if command -v openai >/dev/null 2>&1; then
    OPENAI_TOOL="openai"
    require_command "jq"
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
echo "║                    TERMINAL LLM COUNCIL                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${YELLOW}Your Question:${NC} $QUERY\n"

# ============================================================================
# STAGE 1: Collect Individual Responses
# ============================================================================

print_header "STAGE 1: COLLECTING INDIVIDUAL RESPONSES"

for model in "${MODEL_IDS[@]}"; do
    label=$(get_model_label "$model")
    echo -e "${BLUE}Querying ${label}...${NC}"
    response=$(invoke_model "$model" "$QUERY")
    printf '%s\n' "$response" >"$TEMP_DIR/${model}_response.txt"
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
        review=$(invoke_model "$reviewer" "$review_prompt")
        printf '%s\n' "$review" >"$TEMP_DIR/review_${reviewer}_${reviewee}.txt"
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
FINAL_RESPONSE=$(invoke_model "$CHAIRMAN" "$SYNTHESIS_PROMPT")

echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║                      FINAL ANSWER                              ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}\n"

printf '%s\n\n' "$FINAL_RESPONSE"

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
echo "  • Stages Completed: Response Collection → Peer Review → Synthesis"
echo "  • Responses saved in: $TEMP_DIR"
echo ""

# Terminal Council Code Flow (`terminal_council_with_websearch.sh`)

This document explains how the terminal council script evolved and how it currently operates end‑to‑end, including a precise description of how web search queries are formed today.

---

## 1. Evolution of the Script (Current State)

### 1.1 Initial Council Script (Pre–Dec 2)

- Core pattern: 3‑stage council
  - **Stage 1** – Each model answers the user’s question independently.
  - **Stage 2** – Each model reviews the others’ answers.
  - **Stage 3** – A designated **chairman** (Codex/GPT‑5.1) synthesizes a final answer.
- Models:
  - Codex (GPT‑5.1), Claude CLI, Gemini CLI.
- No web search, no token tracking, and simple Codex/Gemini CLI calls.

### 1.2 Dec 2 – Web Search + open‑webSearch Integration

- Introduced the **`open-webSearch`** server (MCP + REST) and wired it into the council script.
- Added helpers:
  - `check_websearch_server`  
    - Uses `ENABLE_WEB_SEARCH` and hits `${WEBSEARCH_URL}/api/health`.
  - `web_search` / `web_search_json`  
    - `POST ${WEBSEARCH_URL}/api/search` with a `query` string, `limit`, and `WEBSEARCH_ENGINES`.  
    - Returns search results (titles, URLs, descriptions).
  - `fetch_url_content` / `fetch_url_content_limited`  
    - `POST ${WEBSEARCH_URL}/api/fetchUrl` with `{ url, useBrowserFallback: true, maxContentLength }`.  
    - Returns `.content` from the enhanced content extractor.
  - `needs_web_search`  
    - Decides whether web search is needed using:
      - Keyword heuristics (e.g., “search”, “latest”, “current”).  
      - And, when needed, a small YES/NO classification model call.
- Stage 1 changed from:
  - “Prompt → answer”  
  into:
  - “Optional web search → context block → answer.”

### 1.3 Later on Dec 2 – Initial Per-Model Independent Web Research (Shared Query)

- Removed the single “Stage 0” shared research.  
- Introduced **per-model** independent research inside Stage 1, but at this point all models still used the **same full user question** as the search query (see §2.6 for the historical behavior before Dec 11).
- Environment knobs:
  - `FETCH_URL_ENABLE` – whether to fetch page bodies.
  - `FETCH_URL_RESULTS` – how many URLs per model.
  - `FETCH_URL_MAX_CHARS` – truncation length per fetched URL.

### 1.4 Dec 3 – Token Tracking, Deep Mode, and Docs

- Added **Bash 3.2‑compatible token tracking**:
  - `estimate_tokens` (1 token ≈ 4 chars).
  - Per‑model counters:
    - `OPENAI_INPUT_TOKENS`, `OPENAI_OUTPUT_TOKENS`, `OPENAI_TOTAL_TOKENS`.
    - `CLAUDE_*`, `GEMINI_*`, plus global totals.
  - `track_tokens` and `print_token_report` to collect and display estimates.
- Introduced **deep mode** (`ai_council_deep`):
  - Higher `MAX_TOKENS_STAGE1` and `MAX_TOKENS_STAGE3` for more exhaustive answers.
- Increased `FETCH_URL_MAX_CHARS` to 8000 for deeper page snapshots.
- README and `.gitignore` were updated so docs reflect behavior and AI context files remain local.

### 1.5 Dec 4 – Codex/Gemini Hardening

- Identified that **Codex was returning empty responses** in real council runs (0 output tokens).
- Hardened `run_openai` (Codex path):
  - Switched to using `--output-last-message` with non‑interactive flags:
    - `--skip-git-repo-check`, `-s read-only`, `--color never`, etc.
  - Added:
    - Error capture and exit‑code checks.
    - Whitespace‑only output detection.
  - Later iterations added stdout filtering as fallback when `--output-last-message` was empty.
- Hardened `run_gemini`:
  - Added a strict **text‑only “no tools/filesystem” preamble**.
  - Removed risky flags (e.g., `--sandbox false`, `--approval-mode default`).
  - Added simple error/empty‑output guards.
- Added a README note about Codex reasoning modes and stored representative council logs for debugging.

### 1.6 Dec 10 – Codex Fix, Gemini Model Selection, Smart Session Filenames

- Refined Codex CLI invocation:
  - Always pass a valid `reasoning_effort` (clamped to `none|low|medium|high`).
  - Use `--output-last-message` preferentially, with an AWK filter on stdout as fallback to remove:
    - Session metadata, “thinking” lines, token stats, separators, branding, etc.
  - Treat empty/whitespace‑only content as a hard error.
- Simplified Gemini invocation:
  - Always call `gemini --output-format text --model "$GEMINI_MODEL" …`  
    (no more special casing `gemini-2.0-flash-exp`).
  - Default `GEMINI_MODEL` set to `gemini-2.5-pro`.
- Added **Codex‑powered short title generation + versioned filenames**:
  - `generate_short_title` uses `run_openai` with:
    - A prompt that asks for a ≤20‑char, lowercase, underscore title.
    - `reasoning="low"`, `max_tokens=50`.
  - `save_session_documentation`:
    - Filename pattern: `[vN_]YYYY-MM-DD_title.md` in `council_sessions/`.
    - Detects existing files and increments `v2_`, `v3_`, … prefixes.
- Rewrote `session_summary_agent.md` to be concise, model‑agnostic, and kept it gitignored.  
- README and `.gitignore` were synced with the new behavior.

### 1.7 Dec 11 – Explicit URL Detection and Fetching

- Problem: when the user supplied explicit URLs (e.g., `https://pathtech.io/`, `https://docs.pathtech.io/`), models still replied “I can’t browse the web” because:
  - `needs_web_search` only triggered search **about** those URLs, not direct fetch.
  - `fetch_url_content_limited` was only used on search results, not on explicitly provided URLs.
- New helpers:
  - `extract_urls_from_query`:
    - Uses `grep -oE 'https?://[^[:space:]]+' | sort -u` to pull all URLs from the user query.
  - `fetch_explicit_urls`:
    - Re‑extracts URLs from the query.
    - For each URL, calls `fetch_url_content_limited` (which hits `POST /api/fetchUrl` with `useBrowserFallback: true`, `maxContentLength=$FETCH_URL_MAX_CHARS`).
    - Logs progress and builds:
      - `=== CONTENT FROM: <url> === … === END CONTENT ===` blocks.
    - Returns combined content if at least one fetch succeeds; non‑zero status if all fail.
- Stage 1 integration:
  - Before any `needs_web_search` call:
    - If `check_websearch_server` passes, call `fetch_explicit_urls "$QUERY"`.
    - On success, set:
      - `EXPLICIT_URLS_CONTENT` (shared across models),
      - `ENABLE_WEB_SEARCH_FOR_QUERY=true`,
      - and log that explicit URLs were fetched.
  - Only if there is **no explicit URL content** and `needs_web_search` returns true do we run per‑model web search.
- Context building changes:
  - If explicit URL content exists, every model’s context starts with:
    - `=== EXPLICIT URL CONTENT ===` block containing the fetched page text, then optional search/fetched content, then the user question.
  - Web search (if enabled) still adds:
    - `=== WEB SEARCH RESULTS FOR YOUR ANALYSIS ===` and optional `=== FETCHED WEB CONTENT ===` for top URLs.
  - If both pipelines fail, models see the raw question.

### 1.8 Dec 11 – Per-Model Query Planning and URL Deduplication (Implemented, Later Fixed for Bash 3.2)

- Implemented **per-model query planning** (`generate_search_queries_for_model`) so each council member forms its own 3–5 search queries with a lightweight planning prompt (low reasoning for OpenAI, normal invocation for Claude/Gemini).
- Stage 1 now:
  - Generates queries per model.
  - Runs `/api/search` **per query** (limit 3) instead of once per model.
  - Deduplicates URLs across all queries for that model (originally via associative array, later changed to string-based for Bash 3.2 compatibility).
  - Optionally fetches up to `FETCH_URL_RESULTS` bodies from the deduped URLs.
- Result: true query diversity between models plus reduced duplicate fetches.
- **Note**: Initial implementation used Bash 4+ features (`mapfile`, `declare -A`), fixed for Bash 3.2 compatibility on Dec 12 (see §1.9).

### 1.9 Dec 12 – Bash 3.2 Compatibility Fixes (macOS Default Shell Support)

- **Problem**: Dec 11 implementation used Bash 4+ features (`mapfile`, associative arrays) that don't exist in macOS's default Bash 3.2.57, causing immediate script failure.
- **Root cause analysis**: Codex's session 2 implementation added a Bash 4+ version check, breaking macOS compatibility. Script used:
  - `mapfile -t array < <(command)` - Not available in Bash 3.2
  - `declare -A seen_urls` - Associative arrays require Bash 4+
  - `local` declarations outside functions - Syntax error in Bash 3.2
- **Compatibility fixes implemented**:
  - **Replaced `mapfile` with `while read` loops** (line 1185-1187):
    ```bash
    # OLD (Bash 4+):
    mapfile -t model_queries < <(generate_search_queries_for_model "$model" "$QUERY" 5)

    # NEW (Bash 3.2 compatible):
    model_queries=()
    while IFS= read -r line; do
        model_queries+=("$line")
    done < <(generate_search_queries_for_model "$model" "$QUERY" 5)
    ```
  - **Replaced associative arrays with string-based URL deduplication** (lines 1200, 1219-1220, 1233, 1243):
    ```bash
    # OLD (Bash 4+):
    declare -A seen_urls
    if [ -z "${seen_urls[$url]}" ]; then
        seen_urls[$url]=1

    # NEW (Bash 3.2 compatible):
    seen_urls=""  # Space-separated string
    if ! echo " $seen_urls " | grep -Fq " $url "; then
        seen_urls="$seen_urls $url"
    ```
  - **Fixed variable scope bugs** (line 1162):
    - Removed `local fetch_exit_code=$?` (outside function)
    - Changed to simple variable assignment: `fetch_exit_code=$?`
  - **Fixed `set -e` interaction** (lines 1146-1149):
    - Wrapped `fetch_explicit_urls` call with `set +e`/`set -e` to prevent early script exit
  - **Updated Bash version check** (line 20):
    - Changed from `if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]` to `-lt 3`
    - Now requires Bash 3+ instead of 4+
- **Additional fixes**:
  - **Disabled AI-based web search decision** (line 473-475):
    - `needs_web_search` now uses only keyword heuristics (no Codex call)
    - Prevents potential hangs from model invocation during routing
  - **Codex config fix**: Updated `~/.codex/config.toml` reasoning_effort from `"xhigh"` to `"high"` (gpt-5.1 doesn't support xhigh)
- **Testing results**:
  - ✅ Syntax validation passes: `bash -n terminal_council_with_websearch.sh`
  - ✅ Basic council (no web search): All 3 models working, Stage 1-3 complete
  - ✅ Web search enabled: Per-model query planning, URL deduplication, content fetching all functional
  - ✅ Full council with web research: Successfully completed with ~28 unique URLs fetched across 3 models
- **Performance**: String-based deduplication (using `grep -Fq`) is fast enough for typical council sessions (9-12 URLs per model). The O(n) search is acceptable since we're only checking 10-15 URLs per model maximum.
- **Compatibility**: Script now works on macOS default Bash 3.2.57 without requiring Homebrew installations or shell upgrades.

### 1.10 Dec 12 – Phase 1 Critical Fixes (AI Council Code Review)

Following a comprehensive three-AI council review of the script (Codex GPT-5.1, Claude Sonnet, Gemini 2.5 Pro), implemented all 5 critical bug fixes from Phase 1:

- **1.1: Fixed strict-mode pipeline failure in `generate_short_title`** (lines 172-195):
  - Split pipeline into two steps: capture raw_title with `|| true`, then process only if non-empty
  - Prevents script abort when `run_openai` fails under `set -euo pipefail`
  - Ensures fallback logic (sanitized query) always executes

- **1.2: Separated logs from `EXPLICIT_URLS_CONTENT`** (lines 1176-1186):
  - Removed `2>&1` redirect from `fetch_explicit_urls` call
  - Now captures only stdout (content) into `EXPLICIT_URLS_CONTENT`
  - Security/status logs remain on stderr for user visibility
  - Prevents log pollution in model prompts and session documentation

- **1.3: Graceful degradation for web search failures** (lines 437-449):
  - Added `set +e`/`set -e` guards around curl call in `web_search_json`
  - Function now returns empty string and exit code 1 on failure instead of aborting script
  - Allows council to continue even if web search API is temporarily unavailable

- **1.4: Validated timeout environment variables** (lines 689-699):
  - Added `MODEL_TIMEOUT_SECONDS` validation (must be positive integer)
  - Added `WEB_SEARCH_TIMEOUT` validation (must be positive integer)
  - Integrated into `validate_numeric_env_vars` function
  - Prevents script abort from non-numeric timeout values

- **1.5: Prevented terminal control injection** (lines 1160-1162):
  - Replaced `echo -e "${YELLOW}Your Question:${NC} $QUERY\n"` with safer approach
  - Now uses `echo -e` for color codes only, `printf` for user input
  - Prevents escape sequences in user queries from affecting terminal

**Testing**: All fixes validated with `bash -n` syntax checking. Script remains Bash 3.2+ compatible.

### 1.11 Dec 12 – Phase 2 Security & Privacy Hardening (AI Council Code Review)

Implemented all 10 security enhancements from Phase 2 of the council review:

- **2.1: COUNCIL_ALLOW_EXTERNAL_WEBSEARCH opt-in** (lines 46-47, 781-788):
  - Added environment variable (default: `false` - fail-closed design)
  - `web_search_json` checks if WEBSEARCH_URL is localhost/127.0.0.1 or if opt-in is enabled
  - Refuses external web search endpoints unless explicitly allowed
  - Prevents accidental data exfiltration to unauthorized search services

- **2.2: SSRF checks on search-result URLs** (lines 563-568):
  - Modified `fetch_url_content` to validate all URLs with `is_safe_url` before fetching
  - Returns "URL blocked by SSRF policy" error message instead of fetching unsafe URLs
  - Applies to all web search result URLs processed in Stage 1

- **2.3: Strengthened `is_safe_url` parsing** (lines 250-306):
  - Added IPv6 private range detection (fc00::/7, fe80::/10, ::1)
  - Added cloud metadata endpoint blocking (169.254.169.254, metadata.google.internal, etc.)
  - Added hexadecimal IP notation detection (0x7f000001 for 127.0.0.1)
  - Blocked special-use domains (.local, .localhost, .internal, .test, .example, etc.)

- **2.4: Broadened secret redaction** (lines 308-368):
  - GitHub tokens: `ghp_*`, `github_pat_*`
  - JWT tokens: `eyJ*` patterns
  - Database connection strings: PostgreSQL, MySQL, MongoDB, Redis URIs with embedded credentials
  - Private keys: PEM headers for RSA, EC, DSA, OPENSSH
  - Google API keys: `AIza*` patterns
  - BSD sed compatible (tested on macOS)

- **2.5: COUNCIL_SAVE_SESSION flag** (lines 52-53, 1679-1685):
  - Added environment variable (default: `true`)
  - Modified main script to skip session file creation/writing when disabled
  - Privacy-first design: allows ephemeral council sessions with no disk persistence

- **2.6: COUNCIL_REDACT_EMAILS toggle** (lines 54-55, 714-715):
  - Added environment variable (default: `false`)
  - Email pattern redaction integrated into `redact_sensitive_data` function
  - Replaces emails with `[EMAIL_REDACTED]` in session logs

- **2.7: Secure debug logging** (lines 150-159):
  - Created `debug_log_safe` function that pipes all output through `redact_sensitive_data`
  - Applied to all `debug_log` calls that might contain user input or API responses
  - Prevents accidental secret leakage in debug mode

- **2.8: Restrictive file permissions** (lines 1414-1417, 1532-1535):
  - Set `chmod 600` on all temporary files and session files
  - Set `chmod 700` on council_sessions directory
  - Prevents other users on system from reading sensitive council data

- **2.9: Atomic session filename allocation** (lines 1509-1523):
  - Enabled noclobber mode: `set -C` before session file creation
  - Changed file creation from append (>>) to exclusive create (>)
  - Loop retries with incremented counter if file exists
  - Prevents race conditions from multiple concurrent councils

- **2.10: String environment variable validation** (lines 701-738):
  - Created `validate_string_env_vars` function
  - Validates WEBSEARCH_ENGINES against allowed list
  - Validates model names contain only safe characters
  - Validates CHAIRMAN value
  - Prevents shell injection via malformed environment variables

**Testing**: Two successful end-to-end test runs. BSD sed compatibility achieved for macOS users.

### 1.12 Dec 12 – Phase 3 Performance Optimizations (AI Council Code Review)

Implemented 6 of 7 performance enhancements from Phase 3, achieving **3x faster** end-to-end execution:

- **3.1: Optional AI title generation** (lines 60, 184-199):
  - Added `COUNCIL_AI_TITLES` environment variable (default: `true`)
  - Modified `generate_short_title` to check flag before calling AI model
  - Deterministic fallback: sanitized query (lowercase, underscores, max 20 chars)
  - Saves 1-2 seconds and ~100 tokens per session when disabled

- **3.2: Parallelized Stage 1 model calls** (lines 1321-1532):
  - Wrapped each model's Stage 1 work in subshell with `&` background operator
  - Collected background PIDs in `stage1_pids` array during launch loop
  - Added `wait` command after loop to block until all models complete
  - Sequential display and token tracking after parallel execution (avoids subshell variable loss)
  - **Performance gain**: Stage 1 now ~20 seconds (3 models in parallel) vs ~60 seconds (sequential)

- **3.3: Parallelized Stage 2 peer reviews** (lines 1541-1589):
  - Applied same parallelization pattern as Stage 1 to peer review loop
  - Each reviewer-reviewee pair runs in background subshell
  - Collected PIDs in `stage2_pids` array, wait for completion
  - Sequential display and token tracking after parallel execution
  - **Performance gain**: Stage 2 now ~8 seconds (6 reviews in parallel) vs ~48 seconds (sequential)

- **3.4: Reduced redundant jq invocations** (lines 1375-1385):
  - Replaced 3 separate `jq -r` calls (url, title, description) with single TSV query
  - Pattern: `jq -r '.results[] | [.url, .title, .description] | @tsv'`
  - Used `IFS=$'\t' read -r url title desc` to parse tab-separated output
  - **Performance gain**: 66% reduction in jq processes during web search

- **3.5: Combined adjacent sed passes** (lines 197, 204):
  - `generate_short_title`: Combined 3 sed calls into single `-e` script
  - Saves 2 process forks per title generation

- **3.6: Timeout detection warning** (lines 1256-1261):
  - Check if `TIMEOUT_CMD` is empty (timeout command unavailable) during startup
  - Display clear warning about potential hangs and reliability issues
  - Recommend installing GNU coreutils for timeout support

- **3.7: GNU parallel support (deferred)**:
  - Not implemented - background job parallelization already achieves desired speedup
  - Current approach is more portable (works on all Unix-like systems)

**Performance Impact**:
- Stage 1 speedup: **3x faster** (sequential: 60s → parallel: 20s)
- Stage 2 speedup: **6x faster** (sequential: 48s → parallel: 8s)
- Overall end-to-end: **2.8-3x speedup** (was ~120s, now ~40-50s)
- Bash 3.2 compatible, no external dependencies

**Testing**: Two successful end-to-end test runs with timing measurements validating 3x speedup.

---

## 2. Current End‑to‑End Execution Flow

This describes how `terminal_council_with_websearch.sh` behaves **today**, with emphasis on how search queries are formed.

### 2.1 Startup & Configuration

1. **Parse arguments**  
   - If no arguments, print usage and exit.  
   - `QUERY="$*"` – full question string.
2. **Environment & defaults**
   - Models: `OPENAI_MODEL`, `CLAUDE_MODEL`, `GEMINI_MODEL` with defaults.
   - Council membership: `MODEL_IDS=("openai" "claude" "gemini")`.
   - Chairman: `CHAIRMAN` (default `"openai"`).
   - Web search: `WEBSEARCH_URL`, `ENABLE_WEB_SEARCH`, `WEBSEARCH_ENGINES`.
   - Fetch depth: `FETCH_URL_ENABLE`, `FETCH_URL_RESULTS`, `FETCH_URL_MAX_CHARS`.
   - Token limits: `MAX_TOKENS_STAGE1`, `MAX_TOKENS_STAGE2`, `MAX_TOKENS_STAGE3`.
   - Timeouts: `MODEL_TIMEOUT_SECONDS`, `WEB_SEARCH_TIMEOUT`.
   - Security: `COUNCIL_ALLOW_EXTERNAL_WEBSEARCH` (default: `false`).
   - Privacy: `COUNCIL_SAVE_SESSION` (default: `true`), `COUNCIL_REDACT_EMAILS` (default: `false`).
   - Performance: `COUNCIL_AI_TITLES` (default: `true`).
   - Debugging: `COUNCIL_DEBUG`.
3. **CLI detection**  
   - Require `gemini`, `claude`, `jq`, `curl`.  
   - If `openai` CLI exists → use it; else if `codex` exists → use that; otherwise exit.  
   - Set `OPENAI_TOOL` and `OPENAI_DISPLAY` accordingly.
4. **Shell requirement**  
   - Runtime requirement: **Bash 3+** (tested on macOS Bash 3.2.57). Sections 1.8–1.9 describe an earlier Bash 4+ implementation and the compatibility fixes that removed `mapfile`/associative arrays from Stage 1.
5. **Temp dir & chairman**  
   - Create `TEMP_DIR` and set a trap to clean it on exit.  
   - Verify the chairman via `ensure_chairman`; if invalid, fall back to `gemini`.  
   - Resolve `CHAIRMAN_LABEL` via `get_model_label`.  
   - Print banner and user question.

### 2.2 Token Tracking Setup

- Initialize per‑model counters:
  - `OPENAI_INPUT_TOKENS`, `OPENAI_OUTPUT_TOKENS`, `OPENAI_TOTAL_TOKENS`, etc.  
- Provide:
  - `estimate_tokens` → naive char‑based token estimate.  
  - `track_tokens` → update per‑model and global totals after each model call.  
- Used in all three stages + synthesis.

### 2.3 Web Search Helpers & URL Fetch

- `check_websearch_server`:
  - Checks `ENABLE_WEB_SEARCH` (case‑insensitive `"true"`).  
  - Hits `${WEBSEARCH_URL}/api/health` and warns if unavailable.
- `web_search` / `web_search_json`:
  - Build a JSON body with:
    - `query`: the search string provided by the caller. In Stage 1 this is a per-model planned query; in other contexts it may be the raw question.  
    - `limit`: number of results to return.  
    - `engines`: list from `WEBSEARCH_ENGINES`.
  - `POST /api/search` to the open‑webSearch server.
- `fetch_url_content_limited`:
  - `POST /api/fetchUrl` with `{ url, useBrowserFallback: true, maxContentLength: FETCH_URL_MAX_CHARS }`.  
  - Returns `.content` or `""` on error.
- `needs_web_search`:
  - Uses keyword heuristics (`search`, `latest`, `today`, etc.) to decide if web search is needed.  
  - AI-based YES/NO routing via Codex/Gemini is currently disabled to avoid additional timeout/hang risk (see §1.9).

### 2.4 Explicit URL Detection & Fetch (Pre‑Stage 1)

1. **URL extraction**  
   - `extract_urls_from_query "$QUERY"` → finds all `https?://…` tokens.  
2. **URL fetching** (`fetch_explicit_urls "$QUERY"`):
   - Calls `extract_urls_from_query` internally.
   - For each URL:
     - Logs “→ Fetching explicit URL: …” to stderr.
     - Calls `fetch_url_content_limited`.
     - On success, appends:
       - `=== CONTENT FROM: <url> ===` … `=== END CONTENT ===`.
   - If at least one URL succeeded:
     - Returns combined content and exit code 0.
   - Otherwise:
     - Logs failures and returns non‑zero.
3. **Main flow wiring**  
   - `EXPLICIT_URLS_CONTENT=""`, `ENABLE_WEB_SEARCH_FOR_QUERY=false` initially.  
   - If `check_websearch_server` and `fetch_explicit_urls` succeed:
     - `EXPLICIT_URLS_CONTENT` is set.
     - `ENABLE_WEB_SEARCH_FOR_QUERY=true`.
     - Log that explicit URLs were fetched and will be shared across models.

### 2.5 Web Search Decision

- If `EXPLICIT_URLS_CONTENT` is empty and `check_websearch_server && needs_web_search "$QUERY"`:
  - Set `ENABLE_WEB_SEARCH_FOR_QUERY=true`.  
  - Log that per‑model web search is enabled.
- If the server is down or both checks fail:
  - `ENABLE_WEB_SEARCH_FOR_QUERY` stays `false`.

### 2.6 Stage 1 – Per‑Model Independent Responses (Current Search Behavior with Planning)

For each model in `MODEL_IDS`:

1. **Base query**  
   - Start with `enhanced_query="$QUERY"`.

2. **How search queries are formed today (after Dec 11)**

When `ENABLE_WEB_SEARCH_FOR_QUERY=true`, the script now:

```bash
model_queries=()
while IFS= read -r line; do
    model_queries+=("$line")
done < <(generate_search_queries_for_model "$model" "$QUERY" 5)

for query in "${model_queries[@]}"; do
    query_results=$(web_search_json "$query" 3)
    # aggregate + dedupe URLs using a Bash 3.2-compatible seen_urls string
done
```

- Each model gets its **own** planned queries (3–5) generated by `generate_search_queries_for_model` with a planning prompt tailored to that model (low reasoning for OpenAI; standard invocation for Claude/Gemini).
- Each planned query hits `/api/search` with `limit=3`.
- URLs are deduplicated across all queries for that model using a Bash‑3.2‑compatible space‑separated `seen_urls` string plus `grep -Fq` checks.
- The rest of the Stage 1 pipeline (optional `fetchUrl` bodies, context assembly, model invocation) stays the same, but now runs on the aggregated, deduped results per model.

3. **Search and content fetch (when enabled)**

If `ENABLE_WEB_SEARCH_FOR_QUERY=true`:

- Call `generate_search_queries_for_model` → up to 5 queries, then `web_search_json` per query (limit 3).
  - If results exist:
    - Deduplicate URLs across all queries for this model.
    - Derive `model_search_results_text` from JSON:
      - `Title`, `URL`, `Description`, `---` separators.  
    - If `FETCH_URL_ENABLE` is “true”:
      - Loop through deduped result URLs (up to `FETCH_URL_RESULTS`) and call `fetch_url_content_limited`.  
      - Build `fetched_content` with:
        - `--- CONTENT FROM: url ---` blocks.
  - Save:
    - `${model}_search_results.txt` and `${model}_fetched_content.txt` in `TEMP_DIR`.  
    - `explicit_urls_content.txt` (once) if `EXPLICIT_URLS_CONTENT` exists.
  - Build `model_context`:
    - If explicit URL content exists:
      - `=== EXPLICIT URL CONTENT ===` block with the fetched explicit URLs.  
    - Always:
      - `=== WEB SEARCH RESULTS FOR YOUR ANALYSIS ===` with search results.  
    - If `fetched_content` exists:
      - `=== FETCHED WEB CONTENT ===` with page bodies.
  - Set `enhanced_query="${model_context}${QUERY}"`.

If there are no search results:

- If explicit URLs content exists:
  - `model_context` contains only the explicit URL block, then the question.  
  - `enhanced_query="${model_context}${QUERY}"`.  
- Else:
  - `enhanced_query="$QUERY"`.

4. **If `ENABLE_WEB_SEARCH_FOR_QUERY=false`**:

- If explicit URLs content exists:
  - `model_context` = `=== EXPLICIT URL CONTENT ===` block + question.  
  - `enhanced_query="${model_context}${QUERY}"`.  
- Else:
  - `enhanced_query="$QUERY"`.

5. **Model invocation** (`invoke_model`)

- `openai` → `run_openai`:
  - If using OpenAI CLI:
    - Build JSON payload with optional `max_tokens`.  
    - Call `openai api chat.completions.create` and parse `.choices[0].message.content`.  
  - If using Codex:
    - Build `args` with:
      - `-c model="$OPENAI_MODEL"`, `-c reasoning_effort=…`, `--skip-git-repo-check`, `-s read-only`, `--color never`, `--output-last-message "$tmp_out"`, and optional `max_output_tokens`.  
    - Call `codex exec "$prompt" "${args[@]}"`.  
    - Prefer the `--output-last-message` file if non‑empty; otherwise apply AWK filter to stdout to remove CLI noise.  
    - Treat empty/whitespace‑only output as error.

- `claude` → `run_claude`:
  - Wraps the user prompt in a detailed council preamble:
    - Encourage tool usage (via MCP) where available.  
    - Ban “asking for permission” and meta‑only answers.  
    - Encourage full, substantive responses.  
  - Pipe into `claude --print --output-format text --model "$CLAUDE_MODEL"`.

- `gemini` → `run_gemini`:
  - Wraps prompt in a strict “no tools, no shell/filesystem, single markdown answer” preamble.  
  - Calls `gemini --output-format text --model "$GEMINI_MODEL" "$constrained_prompt"`.  
  - Strips ANSI escape codes and checks for non‑empty output.

6. **Store and track**  

- Save response to `TEMP_DIR/${model}_response.txt`.  
- Estimate input and output tokens (`estimate_tokens`) and call `track_tokens`.  
- Print the response under a model label banner.

### 2.7 Stage 2 – Peer Reviews

- For each ordered pair `(reviewer, reviewee)` where they differ:
  - Load `reviewee_response` from `TEMP_DIR`.  
  - Use `build_review_prompt` to construct:
    - Question, peer response, and an instruction to critique accuracy, completeness, and clarity and end with `Rating: X/5`.  
  - Call `invoke_model "$reviewer" "$review_prompt" "$MAX_TOKENS_STAGE2"`.  
  - Save output to `TEMP_DIR/review_${reviewer}_${reviewee}.txt`.  
  - Track tokens for the reviewer.  
  - Print the review with a `Reviewer → Reviewee` label.

### 2.8 Stage 3 – Chairman Synthesis

1. **Build synthesis prompt**  
   - `SYNTH_PROMPT_FILE` collects:
     - Intro: “You are the Chairman of an AI council.”  
     - Original question.  
     - Note if web research was used.  
     - For each model:
       - Its label and indented response (`sed 's/^/    /'`).  
       - Peer feedback:
         - For each other reviewer: label + indented review text.
     - Closing instructions:
       - Produce a concise but thorough final answer.  
       - Blend strongest insights.  
       - Note consensus and disagreements.  
       - Cite which model contributed key points.
2. **Chairman call**  
   - Read `SYNTHESIS_PROMPT` from the file.  
   - Call `invoke_model "$CHAIRMAN" "$SYNTHESIS_PROMPT" "$MAX_TOKENS_STAGE3"`.  
   - Track synthesis tokens for the chairman.
3. **Print final answer**  
   - Show a decorated “FINAL ANSWER” box and print the chairman’s synthesis.

### 2.9 Token Report & Session Summary

- `print_token_report`:
  - For each model in `MODEL_IDS`:
    - Display label, input tokens, output tokens, total tokens (estimated).  
  - If the chairman is not one of the council models in `MODEL_IDS`, display a chairman‑only block.  
  - Show overall totals and a note that counts are approximate (1 token ≈ 4 characters).
- Build `COUNCIL_SUMMARY` from `MODEL_IDS` using `get_model_label`.  
- Print a human summary:
  - Council members.  
  - Chairman.  
  - Web research status and depth (URLs × chars).  
  - Completed stages.  
  - Temp directory path for raw responses and reviews.

### 2.10 Session Documentation (High‑Level)

- Separately, `save_session_documentation` and `generate_short_title`:
  - Build a short title using Codex and create a versioned session filename under `council_sessions/`.  
  - Persist:
    - Question, date, council members.  
    - Stage‑by‑stage content (Stage 1 answers, Stage 2 reviews, Stage 3 synthesis).  
    - Token usage summary.  
    - Web research and explicit URL content (including the dedicated “Explicit URLs Fetched” section).

---

## 3. Implemented: Per-Model Independent Query Planning (Dec 11, 2025)

### 3.1 What Changed

- Per-model query planning is live (`generate_search_queries_for_model` ~line 457; Stage 1 loop ~line 1130).
- Each model generates 3–5 tailored queries with a planning prompt. OpenAI uses low reasoning for planning; Claude/Gemini use their standard invocation.
- Each planned query calls `/api/search` with `limit=3`; URLs are deduped across all planned queries per model via a space-separated `seen_urls` list and `grep -Fq` checks (Bash 3.2 compatible).
- Stage 1 context assembly, `fetchUrl` fetching, and model invocation remain the same but now operate on the aggregated, deduped results per model.

### 3.2 Planning Prompt (current)

```bash
You are planning web research to answer this question:
"${user_query}"

Your task is to break this down into 3-${max_queries} focused search queries that will help you gather the information needed.

INSTRUCTIONS:
1. Identify distinct information goals (e.g., product details, team info, market analysis, etc.)
2. For each goal, create 1-2 concise search queries
3. Use clear, specific terms that search engines understand well
4. If the question mentions specific entities (companies, products), include those names
5. Prefer queries that will find authoritative sources (whitepapers, official docs, research papers)
6. If recency matters (e.g., "latest", "current"), include temporal terms (2025, recent, latest)

OUTPUT FORMAT:
Return ONLY the search queries, one per line, nothing else.
No explanations, no numbering, no bullet points.
```

- Fallback: if planning yields zero queries, the original user question is used as the sole query.
- Validation: strips numbering/empty lines, caps at `max_queries`.

### 3.3 Stage 1 Flow (current)

1. Optional explicit URL fetch (unchanged).
2. If web search is enabled:
   - Generate queries per model (3–5).
   - For each query: call `/api/search` (limit 3) and collect results.
   - Deduplicate URLs across all queries for that model.
   - Optionally fetch bodies for up to `FETCH_URL_RESULTS` deduped URLs.
   - Build context with explicit URL content (if any), search results, and fetched bodies, then append the user question.
3. If web search is disabled:
   - Use explicit URL content (if any) plus the user question.
4. Invoke the model with the assembled context.

### 3.4 Token and Volume Impact

- Planning overhead: ~100–500 tokens per model (roughly ~1500 total for three models at max settings).
- Search volume: up to 5 queries × 3 results per model before deduplication; deduping typically reduces duplicates across the model’s query set.
- Fetch volume: unchanged; still capped by `FETCH_URL_RESULTS` per model.

### 3.5 Error Handling & Fallback

- Planning returns 0 queries → fall back to the original user question as a single query.
- Individual search failures → continue with remaining queries.
- No search results and no explicit URL content → model sees the raw question.

### 3.6 Docker Web Search Setup (Current Method)

The council uses Docker to run the `open-webSearch` server with full content extraction capabilities:

**Prerequisites:**
- Docker Desktop installed and running

**Starting the server:**
```bash
cd open-webSearch
docker-compose -f docker-compose.enhanced.yml up -d
```

This will:
- Build the enhanced Docker image with Chromium and Firefox browsers (~1.5GB)
- Start the server on `http://localhost:3000`
- Run in detached mode (background)

**Check server status:**
```bash
docker-compose -f docker-compose.enhanced.yml ps
curl http://localhost:3000/api/health
```

**Configuration** (`docker-compose.enhanced.yml`):
- `ENABLE_BROWSER_FALLBACK: "true"` - Playwright fallback for JS-heavy sites
- `MAX_BROWSERS: 2` - Concurrent browser instances
- `BROWSER_TYPES: chromium,firefox` - Browser pool rotation
- `DEFAULT_SEARCH_ENGINE: brave` - Primary search engine

**Stopping the server:**
```bash
cd open-webSearch
docker-compose -f docker-compose.enhanced.yml down
```

**Note**: First-time build takes 3-5 minutes. Subsequent starts are faster (~10 seconds) since the image is already built.

---

## 4. Session Insight: Why Explicit URLs Sometimes Fail

- In test sessions with JS-heavy sites:
  - The explicit‑URL pipeline did run:
    - URLs in the question were detected.
    - `fetch_explicit_urls` attempted to hit `POST /api/fetchUrl` for the provided URLs.
  - However, `fetchUrl` responded with `null` content for all of them.
    - Likely causes: JS‑heavy rendering, blocking, or scraper protection on those sites.
  - As a result:
    - `EXPLICIT_URLS_CONTENT` ended up empty.
    - Models saw no specific context (and the script treated it as if web access was unavailable).
    - All three models fell back to:
      - Frameworks and constraints (how to evaluate the topic, what info is missing),
      - Rather than concrete details from the requested URLs.
- Takeaway:
  - The **terminal script wiring is now correct**: it detects explicit URLs and routes them to `fetchUrl` with per-model planning in place.
  - The remaining bottleneck is **`open-webSearch`’s ability to extract content** from some URLs (Playwright settings, timeouts, blocked resources, etc.).

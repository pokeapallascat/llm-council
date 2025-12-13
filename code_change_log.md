# Terminal Council Code Change Log

This document records the historical evolution of `terminal_council_with_websearch.sh`, including major refactors, security hardening, and performance work carried out across December 2025.

For the current end-to-end behavior of the script, see `terminal_council_code_flow.md`.

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
- Introduced **per-model** independent research inside Stage 1, but at this point all models still used the **same full user question** as the search query (see §2.6 in earlier docs for the historical behavior before Dec 11).
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
    - Detects existing files and increments `v2_`, `v3_`, etc. to avoid collisions.

### 1.7 Dec 11 – Explicit URL Detection and Fetching

- Implemented explicit URL detection inside the user query:
  - `extract_urls_from_query` finds `https?://...` tokens in the query.
  - `fetch_explicit_urls` fetches content directly from those URLs (with `fetch_url_content_limited`).
- Added an `EXPLICIT_URLS_CONTENT` buffer:
  - If explicit URL fetch succeeds:
    - Appends “CONTENT FROM … / END CONTENT” blocks into `EXPLICIT_URLS_CONTENT`.
    - Marks web search as enabled (`ENABLE_WEB_SEARCH_FOR_QUERY=true`).
    - Ensures the same explicit URL content is available to all models in Stage 1.
- Wired into Stage 1:
  - Before any `needs_web_search` call:
    - The script now checks for explicit URLs and attempts to fetch them.
  - Explicit content is prepended to each model’s context when present.

### 1.8 Dec 11 – Per-Model Query Planning and URL Deduplication (Implemented, Later Fixed for Bash 3.2)

- Introduced **per-model query planning**:
  - Instead of using the raw user question for search, each model now:
    - Generates several focused search queries via a planning prompt.
    - Calls `/api/search` for each planned query.
    - Deduplicates URLs across all queries for that model.
- Initial implementation used Bash 4+ features:
  - `mapfile` to gather lines from `generate_search_queries_for_model`.
  - Associative arrays (`declare -A`) for URL deduplication.
- This version improved research quality but broke on macOS’s default Bash 3.2.

### 1.9 Dec 12 – Bash 3.2 Compatibility Fixes (macOS Default Shell Support)

- Rewrote Stage 1 planning/dedup logic to be Bash 3.2 compatible:
  - Replaced `mapfile` with `while read` loops and `model_queries+=()` arrays.
  - Replaced associative arrays with a simple `seen_urls` space-separated string and `grep -Fq` dedup.
- Updated `terminal_council_code_flow.md` to clarify that:
  - Bash 3+ is required (no longer Bash 4+).
  - `needs_web_search` now uses only keyword heuristics (no Codex call)
  - Prevents potential hangs from model invocation during routing
- Codex config fix:
  - Updated `~/.codex/config.toml` `reasoning_effort` from `"xhigh"` to `"high"` (gpt-5.1 doesn't support `xhigh`).
- Testing results:
  - `bash -n terminal_council_with_websearch.sh` passes.
  - Basic council (no web search): all 3 models working, Stages 1–3 complete.
  - Web search enabled: per-model query planning, URL deduplication, and content fetching all functional.
  - Full council with web research: successfully completed with ~28 unique URLs fetched across 3 models.
- Performance:
  - String-based deduplication (`grep -Fq` over a small `seen_urls` string) was measured as fast enough for typical sessions (9–12 URLs per model).
- Compatibility:
  - Script confirmed to work on macOS default Bash 3.2.57 without requiring a shell upgrade.

### 1.10 Dec 12 – Phase 1 Critical Fixes (AI Council Code Review)

Following a comprehensive three-AI council review of the script (Codex GPT-5.1, Claude Sonnet, Gemini 2.5 Pro), Phase 1 focused on critical bug fixes:

- **1.1: Fixed strict-mode pipeline failure in `generate_short_title`**:
  - Split pipeline into two steps: capture `raw_title` with `|| true`, then process only if non-empty.
  - Prevents script abort when `run_openai` fails under `set -euo pipefail`.
  - Ensures fallback logic (sanitized query) always executes.

- **1.2: Separated logs from `EXPLICIT_URLS_CONTENT`**:
  - Removed `2>&1` redirect from `fetch_explicit_urls` call.
  - Now captures only stdout (content) into `EXPLICIT_URLS_CONTENT`.
  - Security/status logs remain on stderr for user visibility.
  - Prevents log pollution in model prompts and session documentation.

- **1.3: Graceful degradation for web search failures**:
  - Added `set +e`/`set -e` guards around the curl call in `web_search_json`.
  - Function now returns an empty string and exit code 1 on failure instead of aborting the script.
  - Allows council to continue even if the web search API is temporarily unavailable.

- **1.4: Validated timeout environment variables**:
  - Added `MODEL_TIMEOUT_SECONDS` validation (must be a positive integer).
  - Added `WEB_SEARCH_TIMEOUT` validation (must be a positive integer).
  - Integrated into `validate_numeric_env_vars`.
  - Prevents script abort from non-numeric timeout values.

- **1.5: Prevented terminal control injection**:
  - Replaced `echo -e "${YELLOW}Your Question:${NC} $QUERY\n"` with a safer pattern.
  - Uses `echo -e` for color codes only and `printf` for user input.
  - Prevents escape sequences in user queries from affecting the terminal.

All fixes were validated with `bash -n` syntax checking. Script remains Bash 3.2+ compatible.

### 1.11 Dec 12 – Phase 2 Security & Privacy Hardening (AI Council Code Review)

Implemented all 10 security enhancements from Phase 2:

- **2.1: COUNCIL_ALLOW_EXTERNAL_WEBSEARCH opt-in**:
  - Added environment variable (default: `false` – fail-closed design).
  - `WEBSEARCH_URL` must be localhost/127.0.0.1 unless the opt-in is enabled.
  - Prevents accidental data exfiltration to unauthorized search services.

- **2.2: SSRF checks on search-result URLs**:
  - `fetch_url_content` / `fetch_url_content_limited` validate all URLs with `is_safe_url` before fetching.
  - Returns an SSRF-blocking message instead of fetching unsafe URLs.
  - Applies to all web search result URLs processed in Stage 1.

- **2.3: Strengthened `is_safe_url` parsing**:
  - Added IPv6 private range detection (e.g., fc00::/7, fe80::/10, ::1).
  - Added cloud metadata endpoint blocking (169.254.169.254, `metadata.google.internal`, etc.).
  - Added hexadecimal IP notation detection (e.g., `0x7f000001` for 127.0.0.1).
  - Normalizes hostnames to lowercase and supports bracketed IPv6 extraction so these checks apply reliably.

- **2.4: Broadened secret redaction**:
  - GitHub tokens: `ghp_*`, `github_pat_*`.
  - JWT tokens: `eyJ*` patterns.
  - Database connection strings: PostgreSQL, MySQL, MongoDB, Redis URIs with embedded credentials.
  - Private keys: PEM headers for RSA, EC, DSA, OPENSSH.
  - Google API keys: `AIza*` patterns.
  - BSD `sed` compatible (tested on macOS).

- **2.5: COUNCIL_SAVE_SESSION flag**:
  - Added environment variable (default: `true`).
  - When `false`, the main script skips session file creation/writing.
  - Allows ephemeral council sessions with no disk persistence.

- **2.6: COUNCIL_REDACT_EMAILS toggle**:
  - Added environment variable (default: `false`).
  - Email pattern redaction integrated into `redact_sensitive_data`.
  - Replaces emails with `[REDACTED_EMAIL]` in session logs.

- **2.7: Secure debug logging**:
  - Updated `debug_log` to always route messages through `redact_sensitive_data` before printing.
  - Used for any debug output that might contain user input or API responses.
  - Helps prevent accidental secret leakage in debug mode.

- **2.8: Restrictive file permissions**:
  - Set `chmod 700` on the per-run temporary directory created with `mktemp -d`.
  - Set `chmod 600` on the Codex temporary output file used for `--output-last-message`.
  - Reduces the risk of other users on the system reading sensitive intermediate data.

- **2.9: Atomic session filename allocation**:
  - Enabled noclobber mode (`set -C`) around session file creation.
  - Switched from append (`>>`) to exclusive create (`>`).
  - Retries with incremented version suffix (`v2_`, `v3_`, …) when files exist.
  - Prevents race conditions between concurrent council runs.

- **2.10: String environment variable validation**:
  - Added `validate_string_env_vars`.
  - Validates `WEBSEARCH_ENGINES` against an allowed character set.
  - Validates model names and `CHAIRMAN` value for safe characters.
  - Helps prevent shell injection via malformed environment variables.

### 1.12 Dec 12 – Phase 3 Performance Optimizations (AI Council Code Review)

Implemented 6 of 7 performance enhancements from Phase 3, targeting a ~3x speedup:

- **3.1: Optional AI title generation**:
  - Added `COUNCIL_AI_TITLES` (default: `true`).
  - `generate_short_title` checks this flag before calling the AI.
  - Deterministic fallback: sanitized query (lowercase, underscores, max 20 chars).
  - Saves 1–2 seconds and ~100 tokens per session when disabled.

- **3.2: Parallelized Stage 1 model calls**:
  - Wrapped each model’s Stage 1 work in a background subshell (`&`).
  - Collected PIDs in a `stage1_pids` array and used `wait`.
  - Per-model responses and token tracking are handled sequentially after all jobs finish.
  - Reduced Stage 1 time from ~60s (sequential) to ~20s (parallel, max model time).

- **3.3: Parallelized Stage 2 peer reviews**:
  - Applied the same background-job pattern for all reviewer→reviewee pairs.
  - Collected PIDs in `stage2_pids` and used `wait`.
  - Reduced Stage 2 time from ~48s (sequential) to ~8s (parallel).

- **3.4: Reduced redundant `jq` invocations**:
  - Replaced three separate `jq -r` calls (url, title, description) with a single TSV extraction:
    - `jq -r '.results[] | [.url, .title, .description] | @tsv'`.
  - Parsed via `IFS=$'\t' read -r url title desc`.
  - Achieved ~66% reduction in `jq` process overhead during web search result processing.

- **3.5: Combined adjacent `sed` passes**:
  - In `generate_short_title`, merged multiple `sed` passes into a single command with multiple `-e` expressions.
  - Reduced process forks for each title sanitization.

- **3.6: Timeout detection warning**:
  - Added a startup check for `TIMEOUT_CMD`.
  - When missing, prints a warning about potential hangs and suggests installing GNU coreutils.

- **3.7: GNU `parallel` support**:
  - Considered but deferred as unnecessary.
  - Background job parallelization already provides the desired speedup without extra dependencies.

**Performance impact summary (typical session):**

- Stage 1: ~60s → ~20s (3x faster).
- Stage 2: ~48s → ~8s (6x faster).
- Stage 3: ~12s (unchanged, cannot be parallelized).
- Net end-to-end: ~120s → ~40–50s (about 2.8–3x faster).

---

## 2. Session Insight: Why Explicit URLs Sometimes Fail

These notes capture observed behavior when fetching explicit URLs, which depends on the web search server and target sites, not just the Bash script.

- In test sessions with JavaScript-heavy sites:
  - The explicit‑URL pipeline ran as expected:
    - URLs in the question were detected.
    - `fetch_explicit_urls` attempted to call `POST /api/fetchUrl` for each URL.
  - However, the `fetchUrl` endpoint sometimes responded with `null` content for all URLs.
    - Likely causes: JS‑heavy rendering, aggressive blocking, or scraper protection on those sites.
- As a result:
  - `EXPLICIT_URLS_CONTENT` ended up empty.
  - Models saw no page-specific context, and the script treated the situation as if web access was unavailable.
  - All three models then fell back to:
    - Explaining frameworks and evaluation criteria.
    - Talking about “how to reason about X” rather than using concrete details from the URLs.

**Takeaway:**

- The Bash script’s wiring is correct:
  - It detects explicit URLs and routes them through `fetch_explicit_urls`.
  - When content is returned, it is shared across all models and included in Stage 1 prompts and session logs.
- The remaining bottleneck for some URLs is in the **`open-webSearch`** server or the target sites:
  - Playwright/browser configuration.
  - Timeouts and blocking behavior.
  - Anti-scraping techniques on the destination pages.


# Terminal Council Code Flow (`terminal_council_with_websearch.sh`)

This document describes the current end-to-end behavior of `terminal_council_with_websearch.sh`, based solely on the script implementation.

For historical evolution and past refactors, see `code_change_log.md`.

---

## 1. Operator Mental Model

### 1.1 What happens when you run the script

- You run:
  - `./terminal_council_with_websearch.sh "your question here"`
- The script:
  - Validates your shell and CLI tools.
  - Prints a banner and echoes your question (safely).
  - Runs a 3‑stage process:
    - **Stage 1 – Individual answers:** each model answers independently, optionally using web search and explicit URLs from your question.
    - **Stage 2 – Peer review:** each model critiques the others and gives `Rating: X/5`.
    - **Stage 3 – Final answer:** the chairman model reads all answers + reviews and produces a single synthesis.
  - Prints a token usage report.
  - Optionally saves a detailed Markdown transcript under `council_sessions/`.

### 1.2 What you see in the terminal

- Color-coded sections:
  - Headers like `STAGE 1: COLLECTING INDIVIDUAL RESPONSES`.
  - Model labels such as `[OpenAI CLI (gpt-5.1)]`, `[Claude CLI (sonnet)]`, `[Gemini CLI (gemini-2.5-pro)]`.
- Web search status:
  - Messages like:
    - `Explicit URLs detected and fetched - content will be provided to all models`
    - `Web search enabled - each model will perform independent research`
    - Or warnings if the web search server is unavailable.
- Optional debug lines (when `COUNCIL_DEBUG=true`):
  - `[DEBUG]` messages summarizing planning queries, search timings, and failures (with secrets redacted).

### 1.3 Where things are stored

- Temporary files (responses, prompts, research snippets):
  - Created under a per-run `TEMP_DIR` (shown at the end of the run).
  - Automatically cleaned up when the script exits.
- Persistent session logs (if enabled):
  - Markdown files in `council_sessions/` named like:
    - `YYYY-MM-DD_short_title.md`
    - or `v2_YYYY-MM-DD_short_title.md` if a name already exists.
  - Include redacted copies of prompts, research, responses, reviews, and token usage.

---

## 2. Requirements and Startup

### 2.1 Shell and core commands

- Shell:
  - Requires **Bash 3+** (`BASH_VERSINFO[0]` check).
  - Runs with `set -euo pipefail`.
- Required commands (validated at runtime with `require_command`):
  - `gemini`, `claude`, `jq`, `curl`, `perl`.
- Timeout command:
  - `TIMEOUT_CMD=$(command -v timeout || true)`.
  - If not found:
    - Script prints a warning about missing timeout support.
    - Continues without timeout protection for model/web-search calls.

### 2.2 CLI selection and chairman

- `MODEL_IDS=("openai" "claude" "gemini")`.
- `CHAIRMAN` (default: `"openai"`).
  - `ensure_chairman` verifies that `CHAIRMAN` is one of the `MODEL_IDS`, and falls back to `gemini` if not.
- OpenAI vs Codex:
  - If `openai` CLI exists:
    - `OPENAI_TOOL="openai"`.
    - `OPENAI_DISPLAY="OpenAI CLI (${OPENAI_MODEL})"`.
  - Else, if `codex` exists:
    - `OPENAI_TOOL="codex"`.
    - `OPENAI_DISPLAY="Codex CLI (${OPENAI_MODEL} - High Reasoning)"`.
  - Else:
    - Script exits with an error message.

### 2.3 Query handling and banner

- If no arguments are provided, the script prints usage and exits.
- Otherwise:
  - Collects the full question as `QUERY="$*"`.
  - Prints a banner, a colored “Your Question:” label, and then your question via `printf` (so control characters in your input are not interpreted).

---

## 3. Configuration (Environment Variables)

All configuration is via environment variables, with defaults defined at the top of the script.

### 3.1 Models and council configuration

- `OPENAI_MODEL` (default: `"gpt-5.1"`)
- `CLAUDE_MODEL` (default: `"sonnet"`)
- `GEMINI_MODEL` (default: `"gemini-2.5-pro"`)
- `MODEL_IDS=("openai" "claude" "gemini")`
- `CHAIRMAN` (default: `"openai"`)

### 3.2 Timeouts

- `MODEL_TIMEOUT_SECONDS` (default: `45`)
- `WEB_SEARCH_TIMEOUT` (default: `20`)

Both are validated as positive integers in `validate_numeric_env_vars`.

### 3.3 Web search configuration

- `WEBSEARCH_URL` (default: `"http://localhost:3000"`)
- `ENABLE_WEB_SEARCH` (default: `"true"`, case-insensitive)
- `WEBSEARCH_ENGINES` (default: `"duckduckgo,brave"`)
- `COUNCIL_ALLOW_EXTERNAL_WEBSEARCH`:
  - Not given a default at assignment time; used via `COUNCIL_ALLOW_EXTERNAL_WEBSEARCH:-false`.
  - When not `"true"`, `validate_websearch_url` enforces `WEBSEARCH_URL` to point to localhost (`http://localhost:PORT` or `http://127.0.0.1:PORT`).
  - When `"true"`, external endpoints are allowed but a warning is printed.

`WEBSEARCH_ENGINES` is validated in `validate_string_env_vars` to only contain `[a-zA-Z0-9,_-]`.

### 3.4 Fetch depth and token limits

- Fetch configuration:
  - `FETCH_URL_ENABLE` (default: `"true"`)
  - `FETCH_URL_RESULTS` (default: `5`)
    - Must be a positive integer (`>= 1`).
  - `FETCH_URL_MAX_CHARS` (default: `8000`)
    - Must be an integer `>= 100`.
- Token limits:
  - `MAX_TOKENS_STAGE1` (default: `4000`) – Stage 1 responses.
  - `MAX_TOKENS_STAGE2` (default: `500`) – Stage 2 peer reviews.
  - `MAX_TOKENS_STAGE3` (default: `6000`) – Stage 3 synthesis.

All `MAX_TOKENS_*` values are validated in `validate_numeric_env_vars` to be numeric and above minimal thresholds.

### 3.5 Session, privacy, and debug controls

- `COUNCIL_SAVE_SESSION`:
  - Checked via `COUNCIL_SAVE_SESSION:-true`.
  - Default behavior:
    - When unset or `"true"`, the script writes a Markdown session file via `save_session_documentation`.
    - When `"false"`, the script prints a warning and **does not** write any session file.
- `COUNCIL_REDACT_EMAILS`:
  - Checked via `COUNCIL_REDACT_EMAILS:-false` inside `redact_sensitive_data`.
  - When `"true"`, email addresses are replaced with `[REDACTED_EMAIL]` in any text passed through `redact_sensitive_data`.
- `COUNCIL_DEBUG`:
  - When `"true"`, `debug_log` emits debug messages about planning and search, with sensitive data redacted.
- `COUNCIL_AI_TITLES`:
  - Default: `"true"`.
  - Controls whether `generate_short_title` uses an AI call or falls back to a deterministic sanitized query.

---

## 4. Core Helpers and Token Tracking

### 4.1 Output helpers

- Color variables: `RED`, `GREEN`, `YELLOW`, `BLUE`, `MAGENTA`, `CYAN`, `NC`, `BOLD`.
- `print_header "TEXT"`:
  - Prints a stylized header with the provided text.
- `print_model "LABEL"`:
  - Prints a colored `[LABEL]` prefix on its own line.

### 4.2 Debug logging and redaction

- `debug_log "message..."`:
  - Active only when `COUNCIL_DEBUG="true"`.
  - Calls `redact_sensitive_data` on the message before printing.
  - Prints `[DEBUG] ...` messages to stderr.
- `redact_sensitive_data TEXT`:
  - Masks common secrets (API keys, OAuth tokens, DB URIs, AWS keys, private-key headers).
  - Optionally masks email addresses as `[REDACTED_EMAIL]` when `COUNCIL_REDACT_EMAILS="true"`.

### 4.3 URL safety

- `is_safe_url URL`:
  - Returns 0 if URL is allowed, non-zero otherwise.
  - Rules:
    - Protocol must be `http://` or `https://`.
    - Host is extracted from the URL:
      - Supports both IPv4/hostname and bracketed IPv6 (`http://[::1]:8080`).
      - Normalized to lowercase.
    - Blocks:
      - `localhost`, `127.*`, `::1`, `0.0.0.0`.
      - Private IPv4 ranges: `10.*`, `172.16–31.*`, `192.168.*`.
      - Link-local IPv4: `169.254.*`.
      - IPv6 private/local ranges (`fc*`, `fd*`, `fe80*` patterns).
      - IPv4-mapped loopback: `::ffff:127.*`.
      - Cloud metadata endpoints:
        - `169.254.169.254`
        - `metadata.google.internal`
        - `metadata.google.com`
        - `169.254.169.254.nip.io`
      - Hexadecimal IP patterns (e.g., `0x7f000001`).
  - On block:
    - Prints a descriptive message to stderr and returns 1.

### 4.4 Token estimation and tracking

- `estimate_tokens TEXT`:
  - Returns `(length(TEXT) / 4)` as a rough token estimate.
- Per-model counters:
  - `OPENAI_*`, `CLAUDE_*`, `GEMINI_*`, plus `TOTAL_INPUT_TOKENS` and `TOTAL_OUTPUT_TOKENS`.
- `track_tokens MODEL INPUT OUTPUT` updates these counters.
- `print_token_report` prints per-model and overall usage, including a separate chairman section when relevant.

---

## 5. Web Search and Explicit URL Handling

### 5.1 Checking web search server availability

- `check_websearch_server`:
  - Normalizes `ENABLE_WEB_SEARCH` to lowercase.
  - If it is not `"true"`, returns 1 (web search effectively disabled).
  - Otherwise:
    - Calls `curl -s -f "${WEBSEARCH_URL}/api/health"`.
    - Returns 0 on success.
    - Prints a warning and returns 1 if the health check fails.

> Running the web search server
>
> In this repo, the recommended way to provide `WEBSEARCH_URL` is the `open-webSearch` Docker stack:
>
> ```bash
> cd open-webSearch
> docker-compose -f docker-compose.enhanced.yml up -d
> ```
>
> This starts the server on `http://localhost:3000`, which matches the script’s default `WEBSEARCH_URL`. See the “Web Search Setup” section in `README.md` for details and troubleshooting.

### 5.2 Web search helpers

- `web_search QUERY LIMIT`:
  - Builds a JSON payload with `query`, `limit`, and `engines` from `WEBSEARCH_ENGINES`.
  - `POST ${WEBSEARCH_URL}/api/search` and pretty-prints `Title/URL/Description` lines.
  - Used only for human-readable output; Stage 1 uses `web_search_json`.

- `web_search_json QUERY LIMIT`:
  - Same payload as `web_search`.
  - Uses `run_with_timeout` and `curl` to send the request.
  - On success: prints raw JSON and returns 0.
  - On failure: logs a debug message (if enabled), prints an empty string, and returns 1.

### 5.3 Fetching URL content

- `fetch_url_content URL [MAX_LENGTH]`:
  - Builds a payload to `POST ${WEBSEARCH_URL}/api/fetchUrl` with `useBrowserFallback: true`.
  - When `MAX_LENGTH` is provided, also sets `maxContentLength` (typically `FETCH_URL_MAX_CHARS`) to bound content size.
  - Returns `.content` or an empty string on error.

### 5.4 Deciding when to use web search

- `needs_web_search QUERY`:
  - Lowercases `QUERY`.
  - Checks for keywords and recency phrases such as:
    - `search`, `find`, `look.up`, `fetch`, `get.news`, `latest`, `current`, `recent`, `today`, `web.search`, `this week`, `this month`, `yesterday`.
  - Returns 0 (web search needed) if any pattern matches.
  - Returns 1 otherwise.
  - The previous AI-based routing is disabled; the current decision logic is keyword-only.

### 5.5 Explicit URLs in the question

- `extract_urls_from_query QUERY`:
  - Greps for `https?://[^[:space:]]+` and returns unique URLs.

- `fetch_explicit_urls QUERY`:
  - Calls `extract_urls_from_query`.
  - If no URLs are found:
    - Returns 1.
  - For each URL:
    - Validates via `is_safe_url`; blocked URLs are logged and counted.
    - Calls `fetch_url_content URL FETCH_URL_MAX_CHARS` for allowed URLs.
    - If content is returned, appends:
      - `=== CONTENT FROM: URL ===`
      - content
      - `=== END CONTENT ===`
    - Tracks total URLs, successes, and blocked counts.
  - If at least one URL succeeded:
    - Logs a success summary to stderr.
    - Prints the combined content.
    - Returns 0.
  - Otherwise:
    - Logs a failure summary and returns 1.

In the main flow:

- `EXPLICIT_URLS_CONTENT` starts as an empty string.
- At the beginning of Stage 1:
  - If `check_websearch_server` succeeds:
    - Temporarily disables `set -e` and calls `fetch_explicit_urls "$QUERY"`.
    - If `fetch_explicit_urls` succeeds and returns non-empty content:
      - Stores it in `EXPLICIT_URLS_CONTENT`.
      - Sets `ENABLE_WEB_SEARCH_FOR_QUERY=true`.
      - Prints a message that explicit URLs were detected and will be provided to all models.

---

## 6. Per-Model Search-Query Planning

### 6.1 Planning function

- `generate_search_queries_for_model MODEL USER_QUERY MAX_QUERIES`:
  - Builds a planning prompt that:
    - Repeats the user question.
    - Asks the model to generate `3–MAX_QUERIES` focused search queries.
    - Includes instructions about distinct information goals, authoritative sources, and recency.
    - Specifies strict output format: one query per line, no numbering or explanations.
  - Calls:
    - For `model=openai`:
      - `run_openai planning_prompt "low" PLANNING_MAX_TOKENS`.
    - For `model=claude` or `model=gemini`:
      - `invoke_model MODEL planning_prompt PLANNING_MAX_TOKENS`.
    - `PLANNING_MAX_TOKENS` is a script constant (default: 500).
  - Parses the result:
    - Uses a `while read` loop.
    - Trims leading/trailing whitespace on each line.
    - Skips empty lines, number-only lines, and lines starting with `#`.
    - Appends valid lines to a `queries` bash array until `MAX_QUERIES` is reached.
  - Fallback:
    - If no queries were parsed:
      - Logs a debug message (if enabled).
      - Prints the original `USER_QUERY` and returns 0.
  - Otherwise:
    - Prints all planned queries, one per line.

---

## 7. Stage 1 – Independent Responses

### 7.1 Determining web search mode

Before launching any model work:

1. Initialize:
   - `ENABLE_WEB_SEARCH_FOR_QUERY=false`.
   - `EXPLICIT_URLS_CONTENT=""`.
2. If `check_websearch_server` succeeds:
   - Temporarily disable `set -e`.
   - Call `EXPLICIT_URLS_CONTENT=$(fetch_explicit_urls "$QUERY")`.
   - Capture the exit code and re-enable `set -e`.
   - If exit code is 0 and `EXPLICIT_URLS_CONTENT` is non-empty:
     - Set `ENABLE_WEB_SEARCH_FOR_QUERY=true`.
     - Print a message that explicit URLs were detected and fetched.
3. If `EXPLICIT_URLS_CONTENT` is still empty:
   - If `check_websearch_server` succeeds and `needs_web_search "$QUERY"` returns 0:
     - Set `ENABLE_WEB_SEARCH_FOR_QUERY=true`.
     - Print a message that web search is enabled based on keyword detection.

### 7.2 Parallel per-model execution

Stage 1 runs all model work in parallel background jobs:

- For each `model` in `MODEL_IDS`, the script starts a background subshell that:
  - Optionally plans model-specific search queries via `generate_search_queries_for_model` when `ENABLE_WEB_SEARCH_FOR_QUERY=true`.
  - For each planned query, calls `web_search_json "$query" 3`, aggregates results, and deduplicates URLs using a `seen_urls` string.
  - Optionally fetches page bodies for up to `FETCH_URL_RESULTS` URLs when `FETCH_URL_ENABLE="true"`, via `fetch_url_content URL FETCH_URL_MAX_CHARS`, and stores results in per-model temp files.
  - Builds an `enhanced_query` composed of:
    - A date header (`Current date: YYYY-MM-DD`) derived from `CURRENT_DATE`.
    - Optional explicit-URL content (if `EXPLICIT_URLS_CONTENT` is non-empty).
    - Optional web search results and fetched-page content.
    - The original `QUERY`.
  - Calls `invoke_model "$model" "$enhanced_query" "$MAX_TOKENS_STAGE1"`, writing:
    - The response to `$TEMP_DIR/${model}_response.txt`.
    - The `enhanced_query` to `$TEMP_DIR/${model}_enhanced_query.txt`.
- If `ENABLE_WEB_SEARCH_FOR_QUERY=false`, each model either:
  - Sees only the original `QUERY`, or
  - Sees explicit-URL content plus the `QUERY` when `EXPLICIT_URLS_CONTENT` is present.

After launching all background jobs, the script prints a “waiting” message and calls `wait` until all subshells complete.

### 7.3 Collecting Stage 1 results

Once all jobs are done:

- For each `model` in `MODEL_IDS`:
  - Reads `response` and `enhanced_query` from the temp files.
  - Estimates input/output tokens using `estimate_tokens` and calls `track_tokens`.
  - Prints the model label and response.

---

## 8. Stage 2 – Peer Reviews

### 8.1 Parallel review execution

- Prints a Stage 2 header.
- For each ordered pair `(reviewer, reviewee)` with `reviewer != reviewee`:
  - Launches a background subshell that:
    - Reads `reviewee_response` from `$TEMP_DIR/${reviewee}_response.txt`.
    - Builds a review prompt via `build_review_prompt "$QUERY" "$reviewee_response"`.
      - The prompt:
        - Restates the question.
        - Shows the peer response between `<<<` and `>>>`.
        - Asks for a concise critique in 2–3 sentences.
        - Requires a final `Rating: X/5` line.
    - Prints a message (`[Reviewer] reviewing [Reviewee]...`).
    - Calls `invoke_model "$reviewer" "$review_prompt" "$MAX_TOKENS_STAGE2"`.
    - Writes:
      - The review to `$TEMP_DIR/review_${reviewer}_${reviewee}.txt`.
      - The review prompt to `$TEMP_DIR/review_prompt_${reviewer}_${reviewee}.txt`.
  - Stores the subshell PID in `stage2_pids`.

After all review jobs are started:

- Prints a waiting message and calls `wait` until all review jobs complete.

### 8.2 Collecting Stage 2 results

Once all reviews are finished:

- For each `(reviewer, reviewee)` with `reviewer != reviewee`:
  - Reads the review and its prompt from the temp files.
  - Estimates tokens and calls `track_tokens "$reviewer" input_tokens output_tokens`.
  - Prints the review under a `${reviewer_label} → ${reviewee_label}` label.

---

## 9. Stage 3 – Final Synthesis

### 9.1 Building and sending the synthesis prompt

- Prints a Stage 3 header.
- Builds `SYNTH_PROMPT_FILE` in `TEMP_DIR` that:
  - Describes the chairman role and includes `Question: $QUERY`.
  - Notes when Stage 1 used web research (`ENABLE_WEB_SEARCH_FOR_QUERY=true`).
  - For each model:
    - Embeds the model’s response and all peer reviews on that response.
  - Ends with instructions to synthesize a concise but thorough final answer, highlight consensus/disagreement, and cite contributing models.
- Reads the file into `SYNTHESIS_PROMPT` and calls:
  - `FINAL_RESPONSE=$(invoke_model "$CHAIRMAN" "$SYNTHESIS_PROMPT" "$MAX_TOKENS_STAGE3")`.
- Estimates tokens for the synthesis prompt and response and calls `track_tokens` for the chairman.

- If `CHAIRMAN_WEB_SEARCH=true` and the web-search server is healthy:
  - Before building the final synthesis prompt, the chairman generates up to 3 fact-checking queries from the Stage 1 responses and runs `web_search_json` using `SEARCH_RESULTS_PER_QUERY`.
  - The resulting research is included in a `=== CHAIRMAN FACT-CHECKING RESEARCH ===` block in the synthesis prompt, and the chairman is explicitly instructed to use it to verify or correct factual claims.

### 9.2 Printing the final answer and token report

- Prints a “FINAL ANSWER” banner.
- Prints `FINAL_RESPONSE`.
- Calls `print_token_report` to show:
  - Per-model token usage.
  - Chairman token usage (if distinct).
  - Overall totals.

---

## 10. Summary and Session Documentation

### 10.1 Run summary

After the token report:

- Builds `COUNCIL_SUMMARY` by concatenating model labels from `MODEL_IDS` via `get_model_label`.
- Prints:
  - Council members.
  - Chairman label.
  - Whether web research was enabled:
    - If `ENABLE_WEB_SEARCH_FOR_QUERY=true`:
      - States that each model performed independent research via `WEBSEARCH_URL`.
      - Shows `FETCH_URL_RESULTS` and `FETCH_URL_MAX_CHARS`.
    - Otherwise:
      - States that web research was disabled or unavailable.
  - A summary of stages completed:
    - “Independent Research → Response Collection → Peer Review → Synthesis”.
  - The path to the temporary directory (`TEMP_DIR`) where intermediate files were stored.

### 10.2 Session logging (`save_session_documentation`)

- If `COUNCIL_SAVE_SESSION` is unset or `"true"`:
  - Prints “Saving session documentation...”.
  - Calls `save_session_documentation` and prints the resulting file path.
- If `COUNCIL_SAVE_SESSION="false"`:
  - Prints a warning that session logging is disabled and does not write a file.

`save_session_documentation`:

At a high level, `save_session_documentation`:

1. Ensures `council_sessions/` exists and allocates a unique filename for the session using `generate_short_title` (AI-generated or sanitized query) plus an atomic `set -C` create loop.
2. Writes a Markdown report that:
   - Redacts the original `QUERY` via `redact_sensitive_data`.
   - Records date/time, council members, chairman, and web-research configuration.
   - Includes per-model Stage 1 responses and any associated web-search/fetched-content snapshots.
   - Includes Stage 2 peer reviews grouped by reviewer.
   - Includes the Stage 3 final synthesis from the chairman.
   - Appends a token-usage section using the tracked counters.
3. Returns the filename, which the caller then prints.

---

## 11. Troubleshooting (Operator Cheatsheet)

### 11.1 Web search never seems to run

- In the banner output:
  - Look for:
    - `Web Research: Enabled - Each model performed independent research (via http://localhost:3000)`
    - or `Web Research: Disabled or unavailable`.
- If you always see “Disabled or unavailable”:
  - Check that:
    - `ENABLE_WEB_SEARCH=true` (case-insensitive).
    - `WEBSEARCH_URL` points at your server (by default `http://localhost:3000`).
    - The open-webSearch server is actually running and `/api/health` returns 200.
  - Also check for a warning like:
    - `Warning: Web search server not available at http://localhost:3000`
    - If you see this, the script asked for `/api/health` and the server was down or unreachable.

### 11.2 Web search fails for a custom WEBSEARCH_URL

- If you set `WEBSEARCH_URL` to a non-localhost URL and the script exits early with:
  - `Error: WEBSEARCH_URL must use localhost for security (current: ...)`
  - You must also set:
    - `COUNCIL_ALLOW_EXTERNAL_WEBSEARCH=true`
  - When this is enabled, you will see a warning like:
    - `Warning: Using external WEBSEARCH_URL: https://...`
    - indicating that queries may be sent to a third-party service.

### 11.3 Explicit URLs in the question are ignored

- For a question like:
  - `ai_council "please analyze https://example.com/my-page"`
- Watch the Stage 1 logs:
  - If explicit URLs are detected and fetched you will see:
    - `Explicit URLs detected and fetched - content will be provided to all models`
  - If you do **not** see this:
    - Check that `ENABLE_WEB_SEARCH=true` and the web-search server is reachable.
    - Check stderr for messages like:
      - `✗ Blocked unsafe URL: ...` (SSRF protection via `is_safe_url`).
      - `✗ Failed to fetch any URLs` (the server returned no content).
  - In the saved session file (if enabled), look for an “Explicit URLs Fetched” section under Stage 1.

### 11.4 “Blocked unsafe URL” messages

- If you see lines like:
  - `✗ Blocked unsafe URL: http://127.0.0.1:8000`
  - or `Blocked: cloud metadata service not allowed`
- This is `is_safe_url` doing SSRF protection. To fix:
  - Use publicly routable URLs (no localhost/private IPs/metadata IPs).
  - Do **not** try to point the council at internal services; the script is intentionally fail-closed here.

### 11.5 No session file appears in `council_sessions/`

- At the end of a run, the script either prints:
  - `✓ Session saved to: council_sessions/...`
  - or:
  - `⚠ Session logging disabled (COUNCIL_SAVE_SESSION=false)`
- If you never see a `Session saved to` line:
  - Confirm that:
    - `COUNCIL_SAVE_SESSION` is unset or set to `true`.
  - If it is `false`, this is expected: no Markdown logs will be written.

### 11.6 “Configuration validation failed” at startup

- The script validates numeric and string env vars early. Common causes:
  - Non-numeric values for:
    - `FETCH_URL_RESULTS`, `FETCH_URL_MAX_CHARS`, `MAX_TOKENS_STAGE1/2/3`, `MODEL_TIMEOUT_SECONDS`, `WEB_SEARCH_TIMEOUT`.
  - Invalid characters in:
    - `WEBSEARCH_ENGINES`, `OPENAI_MODEL`, `CLAUDE_MODEL`, `GEMINI_MODEL`, or `CHAIRMAN`.
- Fix:
  - Use only numbers for numeric variables.
  - Use only alphanumerics, `.`, `_`, `/`, `-` for model/CHAIRMAN names.
  - Use only alphanumerics, comma, underscore, and hyphen for `WEBSEARCH_ENGINES`.

### 11.7 Script hangs or runs much longer than expected

- Early in the run, if `timeout` is missing you will see:
  - `Warning: 'timeout' command not found - model calls will run without timeout protection`
  - This means a stuck model or web-search call can hang indefinitely.
- To fix:
  - Install `timeout` (e.g., via coreutils on macOS) so `MODEL_TIMEOUT_SECONDS` and `WEB_SEARCH_TIMEOUT` can be enforced.

### 11.8 Debugging with COUNCIL_DEBUG

- Set:
  - `COUNCIL_DEBUG=true ai_council "your question"`
- You will see additional `[DEBUG]` lines such as:
  - Planned web-search queries per model.
  - Web-search timings and exit codes.
  - Messages like `Web search API call failed, returning empty results`.
- All debug messages are passed through `redact_sensitive_data`, so API keys and other secrets are masked before printing.

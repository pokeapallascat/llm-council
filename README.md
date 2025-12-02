# LLM Council in Your Terminal

This project lets you query multiple LLMs together as a “council.” A single prompt is sent to several models, they review each other, and a designated chairman produces the final answer. The primary supported flow is **terminal-first** using local CLIs (no OpenRouter needed). A web UI exists, but is optional and documented separately.

Flow:
1) **Stage 1: First opinions** – each model answers independently.  
2) **Stage 2: Review** – models anonymously critique/rank each other.  
3) **Stage 3: Final response** – the chairman blends the strongest insights.

Use the terminal scripts (preferred):
- `terminal_council.sh`: core 3‑stage council using your local CLIs (`openai`/`codex`, `claude`, `gemini`). Uses your own CLI credentials; no OpenRouter key required.
- `terminal_council_with_websearch.sh`: same council, plus per‑model web search and optional URL content fetch. Config via env vars (`WEBSEARCH_URL`, `ENABLE_WEB_SEARCH`, `WEBSEARCH_ENGINES`, `FETCH_URL_ENABLE`, `FETCH_URL_RESULTS`, `FETCH_URL_MAX_CHARS`). See `TERMINAL_COUNCIL_INTEGRATION.md` for details.

Optional web research server (if you want web search/URL fetch):
- `open-webSearch/` (MCP + REST). Build/start with:
  ```bash
  cd open-webSearch
  npm install
  npx playwright install chromium firefox
  npm run build
  MODE=http ENABLE_CORS=true DEFAULT_SEARCH_ENGINE=brave node build/index.js
  ```
  Smoke test: `./test_rest_api.sh`. MCP config examples: `open-webSearch/MULTI_CLI_SETUP.md`.

## Vibe Code Alert
Originally a hacky experiment to compare LLMs side by side. Code remains lightweight; adapt as needed.

## Setup

### Terminal flow (Using Exisiting LLMs' subscriptions)
- CLIs: ensure `openai`/`codex`, `claude`, `gemini`, `jq`, `curl` are installed and authenticated.
- Run:
  ```bash
  ./terminal_council.sh "Your question"
  ```
  or with web search:
  ```bash
  ENABLE_WEB_SEARCH=true WEBSEARCH_ENGINES="duckduckgo,brave" \
  ./terminal_council_with_websearch.sh "Your question"
  ```

## Tech Stack (terminal-first)
- **Terminal flows (primary):** `terminal_council.sh`, `terminal_council_with_websearch.sh`
- **Local CLIs:** `openai`/`codex`, `claude`, `gemini`, `jq`, `curl`
- **Web search (optional):** `open-webSearch/` MCP + REST server


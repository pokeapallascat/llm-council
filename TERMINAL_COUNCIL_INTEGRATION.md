# Terminal Council Integration Guide

This document explains how to use the terminal council scripts with and without web search, and how they connect to the `open-webSearch` MCP/REST server.

## Scripts Overview

- `terminal_council.sh`  
  Core 3‑stage council (Responses → Peer Review → Synthesis) using local CLIs: `openai`/`codex`, `claude`, and `gemini`.
- `terminal_council_with_websearch.sh`  
  Same council flow, but with an optional **Stage 0: Web Research** powered by `open-webSearch` (REST + MCP).

## Requirements

- CLIs on `PATH`:
  - `gemini` and `claude` (required)
  - `openai` **or** `codex`
  - `jq`
- Backend web app (optional): `uv run python -m backend.main`
- Frontend web app (optional): `cd frontend && npm run dev`
- Web search server (for `_with_websearch`):
  - `cd open-webSearch`
  - `npm install && npx playwright install chromium firefox && npm run build`
  - `MODE=http ENABLE_CORS=true DEFAULT_SEARCH_ENGINE=brave node build/index.js`

Use `open-webSearch/test_rest_api.sh` to confirm REST endpoints are healthy.

## Environment Variables

Common model configuration (both scripts):

- `OPENAI_MODEL` (default `gpt-5.1`)
- `CLAUDE_MODEL` (default `sonnet`)
- `GEMINI_MODEL` (default `gemini-2.0-flash-exp`)
- `CHAIRMAN` – one of `openai|claude|gemini` (default `openai`)

Web search configuration (`terminal_council_with_websearch.sh`):

- `WEBSEARCH_URL` – base URL of open-webSearch (default `http://localhost:3000`)
- `ENABLE_WEB_SEARCH` – `"true"`/`"false"` (case‑insensitive)
- `WEBSEARCH_ENGINES` – comma‑separated engine list (e.g. `duckduckgo, brave`); whitespace is trimmed

## Web Search & MCP Integration

- Stage 0 uses `POST $WEBSEARCH_URL/api/search` and `POST $WEBSEARCH_URL/api/fetchUrl` to build a **web research context** that is prepended to the user query for all models.
- Claude can also call the same server via MCP tools (e.g. `search`, `fetchUrl`) if you configure `web-search` in its `mcp.json`.  
  See `open-webSearch/MULTI_CLI_SETUP.md` for the shared MCP config block.
- `terminal_council_with_websearch.sh` no longer disables tools for Claude; it calls:
  ```bash
  claude --print --output-format text --model "$CLAUDE_MODEL"
  ```
  so MCP tools are available when configured.

## Usage

- Basic council:
  ```bash
  ./terminal_council.sh "Your question here"
  ```
- Council with web research:
  ```bash
  ENABLE_WEB_SEARCH=true WEBSEARCH_ENGINES="duckduckgo,brave" \
    ./terminal_council_with_websearch.sh "Latest LLM evaluation papers?"
  ```

Both scripts save per‑model responses and peer reviews into a temporary directory printed at the end of the run.***

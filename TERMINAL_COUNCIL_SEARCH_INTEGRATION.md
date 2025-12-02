# Terminal Council Integration Guide

This document explains how to use the terminal council scripts with and without web search, and how they connect to the `open-webSearch` MCP/REST server.

## Scripts Overview

- `terminal_council.sh`  
  Core 3‑stage council (Responses → Peer Review → Synthesis) using local CLIs: `openai`/`codex`, `claude`, and `gemini`.
- `terminal_council_with_websearch.sh`
  Same council flow, but each model performs its **own independent** web research before answering. Each model:
  - Performs its own web search query (gets 5 search results)
  - Fetches actual webpage content from up to 5 URLs
  - Receives unique search results and content (up to ~20,000 characters total)
  - Forms responses based on real, fetched web data

  **Key feature**: No centralized Stage 0. Search and URL content fetching happen independently per model inside Stage 1.

## Requirements

- CLIs on `PATH`:
  - `gemini` and `claude` (required)
  - `openai` **or** `codex`
  - `jq`, `curl`
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
- `FETCH_URL_ENABLE` – `"true"`/`"false"` to fetch page content from search results (default `true`)
- `FETCH_URL_RESULTS` – how many top result URLs to fetch content for (default `5`)
- `FETCH_URL_MAX_CHARS` – truncate fetched content to this many chars (default `4000`)

## How Web Search Works

### Automatic Detection
The script automatically determines if web search is needed through:

1. **Keyword Detection** (automatic YES):
   - Detects keywords: `search`, `find`, `look up`, `fetch`, `get news`, `latest`, `current`, `recent`, `today`, `web search`
   - Example: "search for latest news" → automatic web search

2. **AI Decision** (GPT-5.1 fallback):
   - If no keywords detected, asks OpenAI GPT-5.1: "Does this question require current/recent web information?"
   - Uses `run_openai_quick()` without high reasoning effort for fast decisions

### Independent Research Process (Stage 1)

For each model that needs web search:

1. **Web Search**: `POST $WEBSEARCH_URL/api/search` returns 5 search results (titles, URLs, descriptions)
2. **Content Fetching**: `POST $WEBSEARCH_URL/api/fetchUrl` fetches actual webpage content from top URLs (configurable, default 5)
3. **Context Building**: Both search results AND fetched content are prepended to the model's prompt
4. **Model Response**: Each model analyzes its unique research data independently
### MCP Integration (Claude)

Claude can optionally use MCP tools if configured:
- Configure `web-search` in Claude's `mcp.json` (see `open-webSearch/MULTI_CLI_SETUP.md`)
- The script calls: `claude --print --output-format text --model "$CLAUDE_MODEL"`
- MCP tools (`search`, `fetchUrl`) are available when configured
- This provides an additional layer of search capability on top of the REST-based fetching

## Usage Examples

### Basic Council (No Web Search)
```bash
./terminal_council.sh "Explain the attention mechanism in transformers"
```

### Council with Automatic Web Search
The script automatically detects when web search is needed:

```bash
# Keyword "search" triggers automatic web search
./terminal_council_with_websearch.sh "search for latest AI news"

# Keywords "latest" and "current" trigger web search
./terminal_council_with_websearch.sh "what are the latest developments in quantum computing?"

# Explicit "web search" keywords
./terminal_council_with_websearch.sh "do a web search for UK news on December 1st 2025"
```

### Council with Custom Configuration
```bash
# Use specific search engines and fetch more URLs
WEBSEARCH_ENGINES="duckduckgo,brave" \
FETCH_URL_RESULTS=5 \
FETCH_URL_MAX_CHARS=5000 \
  ./terminal_council_with_websearch.sh "Latest LLM evaluation papers?"

# Force web search off (override automatic detection)
ENABLE_WEB_SEARCH=false \
  ./terminal_council_with_websearch.sh "search for something"  # Won't search despite "search" keyword
```

### Setting Up as Global Command (Alias)
```bash
# Add to ~/.zshrc or ~/.bashrc
echo 'alias ai_council="$HOME/ai_Council/terminal_council_with_websearch.sh"' >> ~/.zshrc
source ~/.zshrc

# Use from anywhere
ai_council "search for latest Bitcoin news"
```

## Output

Both scripts save per-model responses and peer reviews into a temporary directory printed at the end. Example output structure:

```
Stage 1: COLLECTING INDIVIDUAL RESPONSES
  Web search enabled - each model will perform independent research

  Querying Codex CLI (gpt-5.1 - High Reasoning)...
    → Performing independent web search for Codex CLI...
    ✓ Search completed
    → Fetching content from top URL(s)...
      → Fetching: https://example.com/article1
      → Fetching: https://example.com/article2
    ✓ Fetched content from 2 URL(s)
  [Codex response with web-informed insights]

  [Repeated for Claude and Gemini...]
```

## Performance Considerations

- **Token Usage**: With `FETCH_URL_RESULTS=5` and `FETCH_URL_MAX_CHARS=4000`, each model receives ~20,000 characters of web content
- **API Costs**: Higher reasoning effort on main responses, but quick decisions use `run_openai_quick()` without reasoning overhead
- **Speed**: Parallel model queries in Stage 1; sequential URL fetching per model (can take 30-60 seconds per model)
- **Reliability**: Graceful degradation if web search fails; models can still respond without web data

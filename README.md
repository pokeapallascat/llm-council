# LLM Council In Your Terminal

Query multiple LLMs together as a "council." Instead of asking a single model, send your prompt to several models at once. They answer independently, review each other anonymously, and a designated chairman produces the final answer.

**Terminal-first workflow.** Uses your existing CLI subscriptions (OpenAI, Anthropic, Google). No OpenRouter key required.

In a bit more detail, here is what happens when you submit a query:

1. **Stage 1: First opinions**. The user query is given to all LLMs individually, and the responses are collected. Each model can optionally perform independent web research before responding.
2. **Stage 2: Review**. Each individual LLM is given the responses of the other LLMs. Under the hood, the LLM identities are anonymized so that the LLM can't play favorites when judging their outputs. The LLM is asked to rank them in accuracy and insight.
3. **Stage 3: Final response**. The designated Chairman of the LLM Council takes all of the model's responses and compiles them into a single final answer that is presented to the user.

## Vibe Code Alert

This project was 99% vibe coded. The codebase has evolved to focus on terminal-first workflows with integrated web search capabilities. Vibe coded with Claude Code, reviewed and optimized by Codex (GPT-5.1).

## Quick Start

### 1. Install and Authenticate CLI Tools

You need these CLI tools **already set up with your existing subscriptions**:
- `gemini` - [Google AI CLI](https://github.com/google/generative-ai-docs/tree/main/demos/palm/cli) (uses your Google AI API key)
- `claude` - [Anthropic Claude CLI](https://docs.anthropic.com/claude/docs/claude-cli) (uses your Anthropic API key)
- `openai` or `codex` - [OpenAI CLI](https://github.com/openai/openai-python) (uses your OpenAI API key)

Plus standard tools:
- `jq` - JSON processor
- `curl` - HTTP client

**No additional accounts or API keys beyond your existing CLI keys** – the scripts reuse whatever you already configured for your CLIs.

### 2. Set Up Global Alias (Recommended)

Add to your `~/.zshrc` or `~/.bashrc`:

```bash
alias ai_council="$HOME/ai_Council/terminal_council_with_websearch.sh"
```

Then reload:
```bash
source ~/.zshrc  # or ~/.bashrc
```

### 3. (Optional) Start Web Search Server

For web-enhanced queries:

```bash
cd open-webSearch
npm install
npx playwright install chromium firefox
npm run build
MODE=http ENABLE_CORS=true DEFAULT_SEARCH_ENGINE=brave node build/index.js
```

## Usage

### Basic Council (no web server required)

```bash
./terminal_council.sh "Explain the attention mechanism in transformers"
```

Or with the alias (calls the web-search-aware script; it will still skip search when not needed):
```bash
ai_council "Explain the attention mechanism in transformers"
```

### Council with Web Search

The script automatically detects when web search is needed based on keywords (`search`, `latest`, `current`, `recent`, `today`, etc.):

```bash
ai_council "search for the latest AI news"
ai_council "what are the latest developments in quantum computing?"
ai_council "find news about Bitcoin on December 1st 2025"
```

Each model independently:
1. Performs its own web search (5 results)
2. Fetches actual webpage content from top 5 URLs (~20,000 characters of real content)
3. Forms responses based on unique research data

## Configuration

### Model Selection

Edit the scripts to change which models participate:

```bash
# In terminal_council_with_websearch.sh
MODEL_IDS=("openai" "claude" "gemini")
CHAIRMAN="openai"

# Model details
OPENAI_MODEL="gpt-5.1"
CLAUDE_MODEL="sonnet"
GEMINI_MODEL="gemini-2.0-flash-exp"
```

### Web Search Settings

Environment variables (all optional):

```bash
# Web search server
WEBSEARCH_URL="http://localhost:3000"           # Server URL
ENABLE_WEB_SEARCH="true"                        # Enable/disable web search
WEBSEARCH_ENGINES="duckduckgo,brave"            # Search engines to use

# URL content fetching
FETCH_URL_ENABLE="true"                         # Fetch webpage content
FETCH_URL_RESULTS=5                             # How many URLs to fetch (default: 5)
FETCH_URL_MAX_CHARS=4000                        # Max chars per URL (default: 4000)
```

### Custom Execution

```bash
# Use specific search engines and fetch more content
WEBSEARCH_ENGINES="duckduckgo,brave" \
FETCH_URL_RESULTS=5 \
FETCH_URL_MAX_CHARS=5000 \
  ai_council "Latest research on LLM evaluation?"

# Force web search off
ENABLE_WEB_SEARCH=false ai_council "search for something"
```

## Tech Stack

- **Core:** Bash scripts orchestrating local CLI tools
- **Models:** OpenAI GPT-5.1 (via codex), Anthropic Claude Sonnet, Google Gemini 2.0 Flash
- **Web Search:** Enhanced fork of [open-webSearch](https://github.com/Aas-ee/open-webSearch) with [mrkrsl/web-search-mcp](https://github.com/mrkrsl/web-search-mcp) features
  - Multi-engine search (DuckDuckGo, Brave, Bing, etc.)
  - Smart content extraction with Playwright fallback for JS-heavy sites
  - Dual transport: MCP (STDIO/HTTP) + REST API
- **Storage:** Temporary files (cleaned up after each run)

## Documentation

- **[TERMINAL_COUNCIL_SEARCH_INTEGRATION.md](TERMINAL_COUNCIL_SEARCH_INTEGRATION.md)** - Complete integration guide
  - How web search works (keyword detection + AI fallback)
  - Independent research architecture
  - Performance considerations
  - MCP configuration for Claude

- **[open-webSearch/MULTI_CLI_SETUP.md](open-webSearch/MULTI_CLI_SETUP.md)** - Multi-CLI web search setup
  - MCP configuration for different CLIs
  - REST API reference
  - Docker deployment

- **[2025-12-02_session_summary.md](2025-12-02_session_summary.md)** - Development history
  - Session 1: Web search integration
  - Session 2: Independent research per model

## Architecture

```
User Query
    ↓
Stage 1: Independent Research + Response Collection
  ├─ Model 1: web search → fetch URLs → respond
  ├─ Model 2: web search → fetch URLs → respond
  └─ Model 3: web search → fetch URLs → respond
    ↓
Stage 2: Peer Review (anonymized)
  ├─ Each model reviews others' responses
  └─ Rankings aggregated
    ↓
Stage 3: Chairman Synthesis
  └─ Final answer combining best insights
```

### Web Search Flow (Per Model)

```
┌─────────────────────────────────────┐
│     open-webSearch Server          │
│     (localhost:3000)                │
│  ┌─────────┐      ┌─────────┐     │
│  │   MCP   │      │  REST   │     │
│  │ (stdio) │      │  API    │     │
│  └────┬────┘      └────┬────┘     │
│       └─────┬──────────┘           │
│             ▼                      │
│    ┌─────────────────┐             │
│    │  Core Services  │             │
│    │ • Multi-engine  │             │
│    │ • Extraction    │             │
│    │ • Browser pool  │             │
│    └─────────────────┘             │
└─────────────────────────────────────┘
         │              │
    ┌────▼────┐    ┌────▼────┐
    │ Claude  │    │ Gemini  │
    │   CLI   │    │ + Codex │
    │  (MCP)  │    │ (REST)  │
    └─────────┘    └─────────┘
         │              │
         └──────┬───────┘
                ▼
    terminal_council_with_websearch.sh
```

## Web UI (Optional, Archived)

A web-based implementation exists but is **optional and archived**. The main development focus is on terminal scripts.

The archived web UI (FastAPI + React + OpenRouter) provides a browser-based interface with conversation history and tab-based stage viewing. It's preserved in the `archive/web-ui` branch.

To use the archived web UI:
```bash
git checkout archive/web-ui
# Follow instructions in ARCHIVE_README.md
```

## Performance

**With Web Search Enabled:**
- **Token Usage**: ~60,000 chars total (3 models × ~20k each)
- **Speed**: 30-60 seconds per model for Stage 1 (search + fetch)
- **Cost Optimization**:
  - Keyword detection = zero API cost
  - Quick routing decisions (no high reasoning)
  - Configurable content limits

## Examples

```bash
# Research query with automatic web search
ai_council "what are the latest breakthroughs in quantum computing?"

# News aggregation
ai_council "search for UK news on December 1st 2025"

# Comparison without web search
ai_council "explain the differences between transformers and RNNs"

# Custom configuration
FETCH_URL_RESULTS=3 ai_council "latest developments in AI safety"
```

## Contributing

This is a personal hack project, but feel free to fork and modify! The codebase is intentionally simple and hackable.


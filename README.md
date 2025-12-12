# LLM Council In Your Terminal

Query multiple LLMs together as a "council." Instead of asking a single model, send your prompt to several models at once. They answer independently, review each other anonymously, and a designated chairman produces the final answer.

**Terminal-first workflow.** Uses your existing CLI subscriptions (OpenAI, Anthropic, Google). No OpenRouter key required.

In a bit more detail, here is what happens when you submit a query:

1. **Stage 1: First opinions**. The user query is given to all LLMs individually, and the responses are collected. Each model can optionally perform independent web research before responding.
2. **Stage 2: Review**. Each individual LLM is given the responses of the other LLMs. Under the hood, the LLM identities are anonymized so that the LLM can't play favorites when judging their outputs. The LLM is asked to critique each response and rate its accuracy, completeness, and clarity (e.g., "Rating: X/5").
3. **Stage 3: Final response**. The designated Chairman of the LLM Council takes all of the model's responses and compiles them into a single final answer that is presented to the user.

## Vibe Code Alert

This project was 99% vibe coded. The codebase has evolved to focus on terminal-first workflows with integrated web search capabilities. Vibe coded with Claude Code, reviewed and optimized by Codex (GPT-5.1).

## System Requirements

- **Bash 3.2+** (macOS default Bash 3.2.57 works perfectly)
- **jq** - JSON processor
- **curl** - HTTP client
- **Node.js 18+** (for web search server)

**macOS Compatibility:** The terminal council script uses Bash 3.2-compatible patterns (string-based URL deduplication, `while read` loops instead of `mapfile`) to work seamlessly with macOS's default shell without requiring Homebrew installations.

## Quick Start

### 1. Install and Authenticate CLI Tools

You need these CLI tools **already set up with your existing subscriptions**:
- `gemini` - [Google AI CLI](https://github.com/google/generative-ai-docs/tree/main/demos/palm/cli) (uses your Google AI API key)
- `claude` - [Anthropic Claude CLI](https://docs.anthropic.com/claude/docs/claude-cli) (uses your Anthropic API key)
- `openai` or `codex` - [OpenAI CLI](https://github.com/openai/openai-python) (uses your OpenAI API key)

> **Codex CLI note:** If you use `codex` instead of `openai`, make sure your Codex CLI profile is set to a supported mode (e.g., model `gpt-5.1` with reasoning `high`, not `xhigh`). Misconfigured reasoning values can crash the council run with “unsupported reasoning.effort” errors.

Plus standard tools:
- `jq` - JSON processor
- `curl` - HTTP client

**No additional accounts or API keys beyond your existing CLI keys** – the scripts reuse whatever you already configured for your CLIs.

### 2. Set Up Global Aliases (Recommended)

Add to your `~/.zshrc` or `~/.bashrc`:

```bash
# Standard council mode
alias ai_council="$HOME/ai_Council/terminal_council_with_websearch.sh"

# Deep mode: More detailed responses with higher token limits
ai_council_deep() {
    MAX_TOKENS_STAGE1=8000 \
    MAX_TOKENS_STAGE3=12000 \
    "$HOME/ai_Council/terminal_council_with_websearch.sh" "$@"
}
```

Then reload:
```bash
source ~/.zshrc  # or ~/.bashrc
```

**Usage:**
- `ai_council "question"` - Standard mode (4K/6K tokens for stages 1/3)
- `ai_council_deep "question"` - Deep mode (8K/12K tokens for more detailed analysis)

### 3. Set Up Web Search Server (Required for Web Research)

The council uses Docker to run the web search server with full content extraction capabilities (including Playwright browsers for JavaScript-heavy sites).

#### Prerequisites

- **Docker Desktop** installed and running ([Get Docker](https://www.docker.com/products/docker-desktop))
- The `open-webSearch` directory must be present (already included in this repo)

#### Starting the Web Search Server

**Open a new terminal window/tab** and run:

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
```

You should see:
```
NAME                      STATUS         PORTS
open-websearch-enhanced   Up X minutes   0.0.0.0:3000->3000/tcp
```

#### Using the Council (in your main terminal)

Now in your **main terminal** (not the one where you started Docker), you can run council queries:

```bash
ai_council "what are the latest breakthroughs in quantum computing?"
```

The council will automatically use the web search server when needed. You can run multiple queries without restarting the server.

#### Stopping the Server

When you're done:

```bash
cd open-webSearch
docker-compose -f docker-compose.enhanced.yml down
```

This stops and removes the container (but keeps the built image for faster next startup).

#### First-Time Build Note

The first time you run `docker-compose up`, it will:
- Build the Docker image (3-5 minutes)
- Install Playwright browsers inside the container
- Start the server

Subsequent starts are much faster (~10 seconds) since the image is already built.

#### Running Without Web Search

If you don't need web research, you can skip the server entirely:

```bash
ENABLE_WEB_SEARCH=false ai_council "your question here"
```

## Usage

**Important:** The project uses a single script (`terminal_council_with_websearch.sh`) that intelligently handles both web-enabled and basic queries. There is no separate "basic" script.

### Basic Council (no web server required)

The script automatically works without the web server if it's unavailable or if you disable web search:

```bash
# Automatic detection (works with or without server)
ai_council "Explain the attention mechanism in transformers"

# Explicitly disable web search
ENABLE_WEB_SEARCH=false ai_council "Explain quantum entanglement"
```

### Council with Web Search

The script automatically detects when web search is needed based on keywords (`search`, `latest`, `current`, `recent`, `today`, etc.):

```bash
ai_council "search for the latest AI news"
ai_council "what are the latest developments in quantum computing?"
ai_council "find news about Bitcoin on December 1st 2025"
```

If your question contains explicit URLs (e.g., `https://example.com/docs`), the council will first try to fetch those URLs directly via the web-search server and prepend their content to each model’s context before running any additional search.

Each model independently:
1. **Formulates its own search queries** (typically 3-5 focused queries per model)
2. Performs web searches (3 results per query, deduplicated to ~9-12 unique URLs)
3. Fetches actual webpage content from top 5 URLs (~40,000 characters of real content - 8,000 chars per URL)
4. Forms responses based on unique research data

This **per-model query planning** ensures research diversity—different models may prioritize different information goals based on their reasoning approach.

### Token Usage Tracking (NEW)

After each council session completes, a **Token Usage Report** is displayed showing estimated token consumption per model and overall totals. This helps you track API usage and costs.

**Example output:**
```
Per-Model Token Usage:
  Codex CLI (gpt-5.1)         Input: xxx  Output: xxx  Total: xxx
  Claude CLI (sonnet)         Input: xxx  Output: xxx  Total: xxx
  Gemini CLI (2.5 Pro)        Input: xxx  Output: xxx  Total: xxx

Overall Token Usage:
  Grand Total: xxx tokens
```

**Note:** Token counts are **estimated** based on character count (1 token ≈ 4 chars). Actual usage varies by model's tokenizer.

### Session Documentation (NEW)

Every council session is **automatically saved** to a markdown file in the `council_sessions/` directory. Each session file includes:

- **Complete conversation context**: Your question, date, council members, and settings
- **Stage 1 - Independent Research & Responses**: For each model:
  - Web search results (if web search was enabled)
  - Full fetched webpage content (if URLs were fetched)
  - The model's complete response
- **Stage 2 - Peer Reviews**: All peer evaluations organized by reviewer
- **Stage 3 - Final Synthesis**: Chairman's comprehensive final answer
- **Token Usage Report**: Per-model and overall token consumption

**File naming format:**
```
council_sessions/YYYY-MM-DD_short_title.md
council_sessions/vX_YYYY-MM-DD_short_title.md  (for repeated queries)
```

**Examples:**
```
council_sessions/2025-12-10_quantum_computing.md
council_sessions/v2_2025-12-10_quantum_computing.md  (second run same day)
```

**How it works:**
- Session titles are AI-generated by default (concise, ~20 characters, descriptive)
- Set `COUNCIL_AI_TITLES=false` to use sanitized query text instead (faster, no AI call)
- Version tracking prevents overwriting previous sessions
- First run gets no version prefix, subsequent runs get `v2_`, `v3_`, etc.

This allows you to:
- Review past council sessions and research
- Compare how different models approached the same question
- Track which sources were consulted
- Audit token usage over time

**Note:** The `council_sessions/` directory is excluded from git (via `.gitignore`) to keep your local research private.

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
GEMINI_MODEL="gemini-2.5-pro"
```

### Web Search Settings

Environment variables (all optional):

```bash
# Web search server
WEBSEARCH_URL="http://localhost:3000"           # Server URL
ENABLE_WEB_SEARCH="true"                        # Enable/disable web search
WEBSEARCH_ENGINES="duckduckgo,brave"            # Search engines to use

# URL content fetching (per model)
FETCH_URL_ENABLE="true"                         # Fetch webpage content
FETCH_URL_RESULTS=5                             # How many URLs to fetch per model (default: 5)
FETCH_URL_MAX_CHARS=8000                        # Max chars per URL (default: 8000 - increased for deeper research)

# Response length configuration
MAX_TOKENS_STAGE1=4000                          # Stage 1: Initial responses (detailed)
MAX_TOKENS_STAGE2=500                           # Stage 2: Peer reviews (concise)
MAX_TOKENS_STAGE3=6000                          # Stage 3: Final synthesis (comprehensive)

# Timeouts & debugging
MODEL_TIMEOUT_SECONDS=45                        # Max seconds per model call (uses `timeout` if available)
WEB_SEARCH_TIMEOUT=20                           # Max seconds for /api/search and /api/fetchUrl calls
COUNCIL_DEBUG=true                              # Enable verbose debug logs for planning/search stages
```

**Note:** MAX_TOKENS settings are enforced for OpenAI/Codex (via the OpenAI CLI or Codex CLI) and treated as best-effort hints for other CLIs, which may still use their own defaults.

### Security & Privacy Settings

Control what data is logged and where web searches are allowed:

```bash
# External web search control (default: false - fail-closed for security)
COUNCIL_ALLOW_EXTERNAL_WEBSEARCH="false"    # Allow non-localhost web search endpoints

# Session logging control (default: true)
COUNCIL_SAVE_SESSION="true"                 # Save session markdown files to council_sessions/

# Email redaction in session logs (default: false)
COUNCIL_REDACT_EMAILS="false"               # Replace email addresses with [EMAIL_REDACTED]

# AI-generated session titles (default: true)
COUNCIL_AI_TITLES="true"                    # Use AI to generate session filenames (vs sanitized query)
```

**Security & Privacy Notes:**
- **`COUNCIL_ALLOW_EXTERNAL_WEBSEARCH`**: ⚠️  By default, the council only allows localhost web search servers (http://localhost:3000 or http://127.0.0.1:3000). Set to `true` to allow external endpoints, but be aware this may send your queries to third-party services.
- **`COUNCIL_SAVE_SESSION`**: Set to `false` for ephemeral sessions with no disk persistence—useful for sensitive queries that you don't want logged.
- **`COUNCIL_REDACT_EMAILS`**: Enable email redaction in session logs to protect privacy. The council also automatically redacts API keys, tokens, database URIs, and private keys.
- **`COUNCIL_AI_TITLES`**: Set to `false` to skip AI title generation (saves ~1-2 seconds and ~100 tokens per session). Falls back to sanitized query text for filenames.

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

- **Core:** Bash 3.2+ scripts orchestrating local CLI tools (macOS-compatible without Homebrew)
- **Models:**
  - OpenAI GPT-5.1 (via codex CLI) - **High reasoning effort** for all stages
  - Anthropic Claude Sonnet
  - Google Gemini 2.5 Pro
- **Web Search:** Enhanced fork of [open-webSearch](https://github.com/Aas-ee/open-webSearch) with [mrkrsl/web-search-mcp](https://github.com/mrkrsl/web-search-mcp) features
  - Multi-engine search (DuckDuckGo, Brave, Bing, etc.)
  - Smart content extraction with Playwright fallback for JS-heavy sites
  - Dual transport: MCP (STDIO/HTTP) + REST API
  - Per-model query planning: each model formulates independent search queries
- **Token Tracking:** Automatic estimation and per-model reporting (Bash 3.2 compatible)
- **Session Documentation:** Automatic markdown file generation with full context and research data
- **Storage:** Session files saved to `council_sessions/`, temporary files cleaned up after each run
- **Compatibility:** String-based URL deduplication, `while read` loops, and other Bash 3.2-compatible patterns for maximum portability

## Documentation

- **[open-webSearch/MULTI_CLI_SETUP.md](open-webSearch/MULTI_CLI_SETUP.md)** - Multi-CLI web search setup
  - MCP configuration for different CLIs
  - REST API reference
  - Docker deployment
- **[websearch_mcp_tools_analysis.md](websearch_mcp_tools_analysis.md)** - Complete analysis of the open-webSearch MCP server
  - Architecture documentation
  - Integration guides
  - File organization reference

## Architecture

```
User Query
    ↓
Stage 1: Independent Research + Response Collection
  ├─ Model 1: formulate queries → search → deduplicate → fetch URLs → respond
  ├─ Model 2: formulate queries → search → deduplicate → fetch URLs → respond
  └─ Model 3: formulate queries → search → deduplicate → fetch URLs → respond
    ↓
Stage 2: Peer Review (anonymized)
  ├─ Each model reviews others' responses
  └─ Rankings aggregated
    ↓
Stage 3: Chairman Synthesis
  └─ Final answer combining best insights
    ↓
Session Documentation
  └─ Saved to council_sessions/YYYY-MM-DD_short_title.md
```

### Web Search Flow (Per Model)

```
┌─────────────────────────────────────┐
│     open-webSearch Docker Server    │
│     (localhost:3000)                │
│  ┌─────────┐      ┌─────────┐       │
│  │   MCP   │      │  REST   │       │
│  │ (stdio) │      │  API    │       │
│  └────┬────┘      └────┬────┘       │
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

**Phase 3 Optimizations (December 2025):**
The council now uses parallel execution for all models in Stage 1 and Stage 2, achieving **3x faster** end-to-end performance compared to sequential execution.

**With Web Search Enabled:**
- **Content Fetched**: ~120,000 chars total (3 models × 5 URLs × 8,000 chars each)
- **Token Usage**: Estimated 15,000-20,000 tokens per session (varies by question complexity)
- **Speed**:
  - Stage 1: ~20 seconds (3 models in parallel doing search + fetch + analysis)
  - Stage 2: ~8 seconds (6 peer reviews in parallel)
  - Stage 3: ~12 seconds (chairman synthesis)
  - **Total: ~40-50 seconds end-to-end** ⚡
- **Speedup**: 3x faster than sequential execution (was ~120 seconds)
- **Cost Considerations**:
  - Keyword detection = zero API cost for routing
  - Codex uses HIGH reasoning effort for deeper analysis (chairman role)
  - Web content increases input tokens significantly vs. basic mode
  - Configurable content limits (FETCH_URL_RESULTS, FETCH_URL_MAX_CHARS)

**Without Web Search (Basic Mode):**
- **Token Usage**: Estimated 6,000-8,000 tokens per session
- **Speed**: ~20-30 seconds total (all stages parallelized)
- **Best for**: Conceptual questions, explanations, comparisons that don't need current data
- **Fast Mode**: Set `COUNCIL_AI_TITLES=false` to skip AI title generation (saves 1-2s + ~100 tokens)

## Examples

### Basic Usage

```bash
# Research query with automatic web search
ai_council "what are the latest breakthroughs in quantum computing?"

# Deep mode for comprehensive analysis
ai_council_deep "explain quantum computing in extensive detail"

# News aggregation
ai_council "search for UK news on December 1st 2025"

# Comparison without web search
ai_council "explain the differences between transformers and RNNs"

# Custom configuration
FETCH_URL_RESULTS=3 ai_council "latest developments in AI safety"
```

### Advanced Usage

**Privacy-Focused Mode:**
```bash
# Ephemeral session - nothing written to disk
COUNCIL_SAVE_SESSION=false ai_council "Help me draft a sensitive email to a client"

# Session with email/secret redaction enabled
COUNCIL_REDACT_EMAILS=true ai_council "Analyze this email thread about our product launch"

# Combined privacy mode (no logging + redaction)
COUNCIL_SAVE_SESSION=false \
COUNCIL_REDACT_EMAILS=true \
  ai_council "Sensitive question here"
```

**Fast Mode (Minimal Latency):**
```bash
# Skip AI title generation + disable web search
COUNCIL_AI_TITLES=false \
ENABLE_WEB_SEARCH=false \
  ai_council "Explain the visitor pattern in software design"
# Result: ~15-20 seconds total (vs ~40-50s with web search)

# Fast mode with deep responses (no web, no title, higher token limits)
COUNCIL_AI_TITLES=false \
ENABLE_WEB_SEARCH=false \
MAX_TOKENS_STAGE1=8000 \
MAX_TOKENS_STAGE3=12000 \
  ai_council "Detailed explanation of distributed consensus algorithms"
```

**External Web Search (Advanced):**
```bash
# ⚠️  Allow external web search endpoint (e.g., hosted search API)
COUNCIL_ALLOW_EXTERNAL_WEBSEARCH=true \
WEBSEARCH_URL="https://search.example.com" \
  ai_council "latest AI research papers"
# Warning: Your queries will be sent to the external service
```

**Combined Use Cases:**
```bash
# Quick ephemeral session with no web search
COUNCIL_SAVE_SESSION=false \
COUNCIL_AI_TITLES=false \
ENABLE_WEB_SEARCH=false \
  ai_council "Quick conceptual question here"
# Result: Fastest possible mode (~15-20s), no disk writes

# Privacy-focused research (logs + redaction + localhost-only web search)
COUNCIL_REDACT_EMAILS=true \
COUNCIL_ALLOW_EXTERNAL_WEBSEARCH=false \
  ai_council "search for information about my company"
# Result: Web search allowed, but only to localhost:3000, emails redacted in logs
```

## Contributing

This is a personal hack project, but feel free to fork and modify! The codebase is intentionally simple and hackable.

# Gemini Code Assistant Context

This document provides a concise overview of the "LLM Council" project, its structure, and how to work with it.

## Project Overview

The "LLM Council" is a project that allows you to query multiple LLMs simultaneously and get a synthesized response. The project has two primary entry points:

1.  **Web Application:** A web-based interface with a Python (FastAPI) backend and a React frontend.
2.  **Terminal CLI Tool:** A shell script (`terminal_council.sh`) that runs the same 3-stage council process in the terminal using local CLIs (`openai`, `claude`, `gemini`).

The core idea is a 3-stage process:

1.  **Stage 1: First Opinions:** The user query is sent to all configured LLMs.
2.  **Stage 2: Review:** Each LLM reviews and ranks the responses of the other LLMs.
3.  **Stage 3: Final Response:** A designated "Chairman" LLM synthesizes a final response based on the initial responses and the peer reviews.

## Tech Stack

### Web Application

*   **Backend:**
    *   Python 3.10+
    *   FastAPI
    *   Uvicorn
    *   HTTPX (for async requests to OpenRouter)
    *   Pydantic
    *   python-dotenv
*   **Frontend:**
    *   React
    *   Vite
    *   `react-markdown`
*   **Package Management:**
    *   `uv` for Python
    *   `npm` for JavaScript

### Terminal CLI Tool

*   Bash script: `terminal_council.sh`
*   Requires local CLIs on `PATH`: `gemini` (required), plus either `openai` or `codex`, and `claude`.
*   Default models (overridable via env vars):
    *   `OPENAI_MODEL=gpt-5.1`
    *   `CLAUDE_MODEL=sonnet`
    *   `GEMINI_MODEL=gemini-2.0-flash-exp`

## Building and Running

### Web Application

**1. Setup:**

*   **Backend:**
    ```bash
    uv sync
    ```
*   **Frontend:**
    ```bash
    cd frontend
    npm install
    cd ..
    ```
*   **API Key:**
    Create a `.env` file in the project root and add your OpenRouter API key:
    ```
    OPENROUTER_API_KEY=sk-or-v1-...
    ```

**2. Running the application:**

*   **Option 1: Use the start script**
    ```bash
    ./start.sh
    ```
*   **Option 2: Run manually**
    *   **Backend:**
        ```bash
        uv run python -m backend.main
        ```
    *   **Frontend:**
        ```bash
        cd frontend
        npm run dev
        ```

The application will be available at `http://localhost:5173`.

### CLI Tool

To run the CLI tool, execute the `terminal_council.sh` script with your query:

```bash
./terminal_council.sh "Your question here"
```

The script requires the `openai`, `claude`, and `gemini` CLI tools to be installed and available in your `PATH`.

### Web Search Integration

This project includes a powerful web search and content extraction server in the `open-webSearch/` directory, which is a fork of `Aas-ee/open-webSearch` enhanced with features from `mrkrsl/web-search-mcp`.

**Server Features:**
- **REST API:** Provides endpoints for web search (`/api/search`) and full-page content extraction (`/api/fetchUrl`).
- **MCP Server:** Can be used directly by the Claude CLI for tool use.
- **Content Extraction:** Uses a combination of Axios/Cheerio for speed and a Playwright-based browser pool (Chromium/Firefox) for complex, JS-heavy sites.

**Terminal Council with Web Search:**
A separate script, `terminal_council_with_websearch.sh`, integrates this server. It adds a "Stage 0" to the council process:
- **Stage 0: Web Research:** Before Stage 1, the script uses Gemini to determine if the query requires web research. If so, it calls the web search API and prepends the results as context for all council members.

**Running the Web Search Council:**
1.  **Start the web search server:**
    ```bash
    # From the project root
    cd open-webSearch
    
    # Install dependencies
    npm install
    
    # Run the server
    npm run start:http 
    # The server will be available at http://localhost:3000
    ```
2.  **Run the web-enabled terminal council:**
    ```bash
    # Set environment variables
    export WEBSEARCH_URL="http://localhost:3000"
    export ENABLE_WEB_SEARCH=true
    
    # Run the script
    ./terminal_council_with_websearch.sh "Your query that might require web search"
    ```

For more details, see `open-webSearch/ENHANCEMENTS.md` and `open-webSearch/MULTI_CLI_SETUP.md`.

## Development Conventions

*   **Backend:**
    *   The backend code is located in the `backend/` directory.
    *   Configuration is in `backend/config.py`.
    *   The main FastAPI application is in `backend/main.py`.
    *   The core council logic is in `backend/council.py`.
    *   Conversations are stored as JSON files in `data/conversations/`.
*   **Frontend:**
    *   The frontend code is in the `frontend/` directory.
    *   Vite-based React SPA. Entry point: `frontend/src/main.jsx`; root component: `frontend/src/App.jsx`.
    *   API calls (including streaming for the 3-stage process) are handled in `frontend/src/api.js`.
*   **Linting:**
    *   The frontend uses ESLint. Run `npm run lint` in the `frontend` directory to check for issues.
    *   MCP/Node projects (`open-webSearch/`, `web-search-mcp/`) use their own `eslint.config.js` and `tsconfig.json`; prefer existing patterns when editing TypeScript.

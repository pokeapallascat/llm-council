# Repository Guidelines

This document is for humans and AI agents working in this repo. It describes how the LLM Council app and related MCP tooling are organized and how to make safe, consistent changes.

## Project Structure & Module Organization

- Root: orchestration scripts and docs – `terminal_council.sh`, `start.sh`, `CLAUDE.md`, `README.md`.
- Backend (Python FastAPI): `backend/` – core council logic, OpenRouter integration, config, and storage helpers.
- Frontend (React + Vite): `frontend/` – UI, static assets, and SPA build.
- Web search MCP servers: `open-webSearch/` (enhanced multi-engine MCP + REST) and `web-search-mcp/` (upstream reference).
- Data and artifacts: `data/` (conversation storage), `solstice_*.md` (research notes), `header.jpg`.

## Build, Test, and Development Commands

- Backend env & deps: `uv sync`
- Run backend: `uv run python -m backend.main`
- Frontend deps: `cd frontend && npm install`
- Run frontend dev server: `cd frontend && npm run dev`
- open-webSearch dev: `cd open-webSearch && npm install && npx playwright install chromium firefox && npm run build`
- web-search-mcp dev: `cd web-search-mcp && npm install && npx playwright install && npm run build`

## Coding Style & Naming Conventions

- Python: follow existing style in `backend/` (PEP 8-ish, descriptive names, no one-letter vars). Prefer small, focused functions.
- TypeScript/JS (MCP + frontend): use project ESLint/Prettier configs (`eslint.config.js`, `tsconfig.json`). Keep imports ordered, avoid unused exports.
- Shell: keep functions in `terminal_council.sh` small and composable; use `set -euo pipefail`.

## Testing Guidelines

- Backend: prefer small, easily testable helpers; if adding tests, mirror existing structure (e.g., `tests/` or module-local tests).
- MCP servers: use `open-webSearch/test_rest_api.sh` and `npm test` or `npm run test` where provided.
- When modifying web search behavior, manually verify `/api/health`, `/api/search`, and `/api/fetchUrl`.

## Commit & Pull Request Guidelines

- Commits: use clear, imperative messages (e.g., `Add MCP REST endpoints`, `Fix council synthesis prompt`).
- PRs: briefly describe behavior changes, affected modules, and any new env vars. Include manual test notes (commands run + observed behavior). Prefer small, focused PRs over broad refactors.

# Archive Branch: Web UI (OpenRouter-based)

This branch preserves the original web-based council implementation.

## What's Archived Here

**Backend** (`backend/`):
- FastAPI server (Python)
- OpenRouter API integration
- 3-stage council logic (Response → Peer Review → Synthesis)
- JSON-based conversation storage

**Frontend** (`frontend/`):
- React UI with Vite
- Tab-based interface for viewing stages
- Conversation history sidebar
- Markdown rendering for responses

## Why Archived

Development focus shifted to terminal-based scripts with integrated web search:
- `terminal_council.sh` - Basic 3-stage council using local CLIs
- `terminal_council_with_websearch.sh` - Enhanced version with independent web research per model

## How to Use This Archive

If you want to run the web UI:

```bash
# Switch to this branch
git checkout archive/web-ui

# Start backend
cd backend
uv run python -m backend.main

# Start frontend (separate terminal)
cd frontend
npm install
npm run dev
```

Then visit http://localhost:5173

## See Also

- Main branch: Terminal scripts with web search integration
- `TERMINAL_COUNCIL_SEARCH_INTEGRATION.md`: Current implementation docs
- `2025-12-02_session_summary.md`: Development history

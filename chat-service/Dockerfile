# Dockerfile — Someday chat-service
# Deploys to Railway. Runs the FastAPI chat API with uvicorn.
#
# WHY uvicorn (async), not gunicorn sync workers (like the extractor):
# the chat endpoint streams Server-Sent Events for the full duration of an
# agentic tool loop (multiple Anthropic calls + web_search). A sync worker would
# tie up a whole process per in-flight stream; uvicorn's async loop multiplexes
# many concurrent SSE streams on one process. No CPU-bound work happens here —
# we're almost always awaiting the Anthropic API or Nominatim — so a single
# async worker handles real concurrency comfortably.

FROM python:3.12-slim

# Python deps. Pinned to match requirements.txt — keep in sync if you bump.
RUN pip install --no-cache-dir \
    fastapi \
    "uvicorn[standard]" \
    anthropic \
    httpx

WORKDIR /app
COPY main.py ./main.py

EXPOSE 8000

# Uses PORT env var injected by Railway; falls back to 8000 for local docker run.
# Shell form so ${PORT} is expanded at runtime.
CMD uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000}

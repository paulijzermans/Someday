# Dockerfile — Someday extractor service
# Deploys to Railway. Runs the Flask extractor API with gunicorn.
# Persistent volume should be mounted at /app/extractor-test-app/cache (videos + places.db — both in cache/).

FROM python:3.12-slim

# System dependencies: ffmpeg (called by transcoder.py via subprocess)
RUN apt-get update && \
    apt-get install -y --no-install-recommends ffmpeg && \
    rm -rf /var/lib/apt/lists/*

# Python dependencies
RUN pip install --no-cache-dir \
    flask \
    flask-cors \
    google-genai \
    python-dotenv \
    yt-dlp \
    requests \
    gunicorn

# Copy source — only what the service needs
WORKDIR /app
COPY extractor/ ./extractor/
COPY extractor-test-app/server.py ./extractor-test-app/server.py
COPY extractor-test-app/ui.html   ./extractor-test-app/ui.html

# Cache dir — map this to a Railway persistent volume
RUN mkdir -p /app/extractor-test-app/cache

WORKDIR /app/extractor-test-app

EXPOSE 5050

# gunicorn: 1 worker process, thread pool (pipeline uses threads internally)
# Uses PORT env var injected by Railway; falls back to 5050 for local docker run.
CMD gunicorn -w 1 -k gthread --threads 4 \
    --bind "0.0.0.0:${PORT:-5050}" \
    --timeout 120 \
    server:app

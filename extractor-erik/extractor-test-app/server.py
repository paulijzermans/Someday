import json
import os
import queue
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeoutError
from pathlib import Path

APP_DIR = Path(__file__).parent
sys.path.insert(0, str(APP_DIR.parent))

# Load .env if present (needed when running directly, not via railway env vars)
_env_path = APP_DIR.parent / ".env"
if _env_path.exists():
    for _line in _env_path.read_text().splitlines():
        _line = _line.strip()
        if _line and not _line.startswith("#") and "=" in _line:
            _k, _v = _line.split("=", 1)
            os.environ.setdefault(_k.strip(), _v.strip())

from flask import Flask, Response, jsonify, request, send_from_directory
from flask_cors import CORS

from extractor import cache_db, downloader, transcoder
from extractor import gemini as gemini_module
from extractor import places as places_module
from extractor.config import REEL_CACHE_ENABLED, PLACE_CACHE_ENABLED

cache_db.DB_PATH = APP_DIR / "cache" / "places.db"
downloader.CACHE_DIR = APP_DIR / "cache"

app = Flask(__name__)
CORS(app)

# ── Auth ───────────────────────────────────────────────────────────────────────
# Set API_KEY env var to protect /run and /result endpoints.
# Leave unset for local development (no auth required).
API_KEY = os.environ.get("API_KEY", "")


def _check_auth():
    if not API_KEY:
        return None  # auth disabled
    if request.headers.get("X-Api-Key", "") != API_KEY:
        return jsonify({"error": "unauthorized"}), 401
    return None


# ── Run store ──────────────────────────────────────────────────────────────────
# run_id → {"q": Queue, "status": pending|done|error, "places": list|None, "error": str|None, "ts": float}
_runs: dict = {}
_runs_lock = threading.Lock()
RUN_TTL = 600  # seconds


def _cleanup_loop():
    """Remove completed runs older than RUN_TTL seconds."""
    while True:
        time.sleep(60)
        cutoff = time.time() - RUN_TTL
        with _runs_lock:
            stale = [rid for rid, r in list(_runs.items()) if r["ts"] < cutoff]
        for rid in stale:
            with _runs_lock:
                _runs.pop(rid, None)


threading.Thread(target=_cleanup_loop, daemon=True).start()


# ── Step helpers ───────────────────────────────────────────────────────────────

STEP_TIMEOUTS = {
    "download":  30,
    "transcode": 30,
    "gemini":    30,
    "places":    15,
}


def _emit(q: queue.Queue, event: str, data: dict):
    q.put(f"event: {event}\ndata: {json.dumps(data)}\n\n")


def _friendly_error(step: str, exc: Exception, timeout=None) -> str:
    msg = str(exc)
    if timeout and isinstance(exc, FuturesTimeoutError):
        labels = {
            "download":  f"Download timed out after {timeout}s — try again",
            "transcode": f"Transcoding timed out after {timeout}s",
            "gemini":    f"Gemini timed out after {timeout}s — try again",
            "places":    f"Places resolution timed out after {timeout}s",
        }
        return labels.get(step, f"{step} timed out after {timeout}s")
    if "429" in msg:
        return "Instagram rate limit — try again in a moment"
    if "timed out" in msg.lower() or "Read timed out" in msg:
        return "Download timed out — Instagram CDN was slow, try again"
    if "login" in msg.lower() or "Login" in msg:
        return "This reel requires Instagram login"
    if "private" in msg.lower():
        return "This reel is from a private account"
    if "404" in msg or "not found" in msg.lower():
        return "Reel not found — it may have been deleted"
    return msg


def _step(q: queue.Queue, name: str, fn, *args, **kwargs):
    timeout = STEP_TIMEOUTS.get(name)
    _emit(q, "step:start", {"step": name})
    t0 = time.time()
    result = None
    error_msg = None
    try:
        if timeout is not None:
            with ThreadPoolExecutor(max_workers=1) as ex:
                result = ex.submit(fn, *args, **kwargs).result(timeout=timeout)
        else:
            result = fn(*args, **kwargs)
    except FuturesTimeoutError as e:
        error_msg = _friendly_error(name, e, timeout)
    except Exception as e:
        error_msg = _friendly_error(name, e)

    ms = int((time.time() - t0) * 1000)
    if error_msg is not None:
        _emit(q, "step:error", {"step": name, "duration_ms": ms, "error": error_msg})
        raise RuntimeError(error_msg)
    _emit(q, "step:done", {"step": name, "duration_ms": ms, "output": result})
    return result


# ── Pipeline ───────────────────────────────────────────────────────────────────

def _run_pipeline(run_id: str, url: str, use_reel_cache: bool, use_place_cache: bool):
    run = _runs[run_id]
    q: queue.Queue = run["q"]
    t_total = time.time()

    try:
        cache_db.init_schema()

        if use_reel_cache:
            import yt_dlp
            with yt_dlp.YoutubeDL({"quiet": True, "skip_download": True, "socket_timeout": 10}) as ydl:
                probe = ydl.extract_info(url, download=False)
            post_id = probe["id"]
            reel = cache_db.get_reel(post_id)
            if reel:
                cache_db.update_views(post_id, probe.get("view_count") or 0)
                places = cache_db.get_places_for_reel(post_id)
                total_ms = int((time.time() - t_total) * 1000)
                _emit(q, "pipeline:done", {"places": places, "total_ms": total_ms, "cached": True})
                _emit(q, "stream:close", {})
                with _runs_lock:
                    run.update(status="done", places=places)
                return

        info       = _step(q, "download",  downloader.download, url)
        video_path = _step(q, "transcode", transcoder.transcode, info["video_path"])
        extracted  = _step(q, "gemini",    gemini_module.extract_places, video_path, info)
        resolved   = _step(q, "places",    places_module.resolve_all_places, extracted, use_place_cache)
        _step(q, "store", cache_db.store_reel, info["post_id"], url, info, resolved)

        total_ms = int((time.time() - t_total) * 1000)
        _emit(q, "pipeline:done", {"places": resolved, "total_ms": total_ms, "cached": False})
        with _runs_lock:
            run.update(status="done", places=resolved)

    except Exception as e:
        total_ms = int((time.time() - t_total) * 1000)
        _emit(q, "pipeline:error", {"error": str(e), "total_ms": total_ms})
        with _runs_lock:
            run.update(status="error", error=str(e))

    _emit(q, "stream:close", {})


# ── Endpoints ──────────────────────────────────────────────────────────────────

@app.route("/health")
def health():
    """Health check — no auth required (used by Railway and iOS on startup)."""
    return jsonify({"status": "ok"})


@app.route("/run", methods=["POST"])
def start_run():
    err = _check_auth()
    if err:
        return err

    body = request.get_json(force=True) or {}
    url = body.get("url", "").strip()
    if not url:
        return jsonify({"error": "url required"}), 400

    use_reel_cache  = bool(body.get("reel_cache",  REEL_CACHE_ENABLED))
    use_place_cache = bool(body.get("place_cache", PLACE_CACHE_ENABLED))

    run_id = str(uuid.uuid4())
    run = {"q": queue.Queue(), "status": "pending", "places": None, "error": None, "ts": time.time()}
    with _runs_lock:
        _runs[run_id] = run

    threading.Thread(
        target=_run_pipeline,
        args=(run_id, url, use_reel_cache, use_place_cache),
        daemon=True,
    ).start()
    return jsonify({"run_id": run_id})


@app.route("/result/<run_id>")
def get_result(run_id: str):
    """Polling endpoint for iOS app — returns status + places once done."""
    err = _check_auth()
    if err:
        return err

    with _runs_lock:
        run = _runs.get(run_id)

    if run is None:
        return jsonify({"error": "run not found"}), 404

    return jsonify({
        "status": run["status"],   # "pending" | "done" | "error"
        "places": run["places"],   # list of place objects, or null
        "error":  run["error"],    # error message string, or null
    })


@app.route("/events/<run_id>")
def events(run_id: str):
    """SSE stream for the web test UI (no auth — localhost only in production)."""
    with _runs_lock:
        run = _runs.get(run_id)
    if run is None:
        return Response("run not found", status=404)

    q = run["q"]

    def generate():
        while True:
            try:
                msg = q.get(timeout=30)
                yield msg
                if "stream:close" in msg:
                    break
            except queue.Empty:
                yield ": keepalive\n\n"

    return Response(
        generate(),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.route("/")
def index():
    return send_from_directory(APP_DIR, "ui.html")


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5050))
    app.run(port=port, debug=False)

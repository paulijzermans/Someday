import yt_dlp
from pathlib import Path

from . import config

# Callers set this to their own cache directory before use
CACHE_DIR = Path(__file__).parent.parent / "extractor-test-app" / "cache"

FORMAT_BEST = "mp4/bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"
FORMAT_480P = "bestvideo[ext=mp4][height<=480]+bestaudio[ext=m4a]/best[height<=480][ext=mp4]/best[ext=mp4]/best"


def download(url: str) -> dict:
    """Download reel and return info dict with added video_path and post_id keys."""
    CACHE_DIR.mkdir(exist_ok=True)

    ydl_opts = {
        "outtmpl": str(CACHE_DIR / "%(id)s.%(ext)s"),
        "quiet": True,
        "no_warnings": True,
        "format": FORMAT_480P if config.LOW_QUALITY_DOWNLOAD else FORMAT_BEST,
        "retries": 2,
        "fragment_retries": 2,
        "socket_timeout": 10,
    }
    if config.CONCURRENT_FRAGMENTS:
        ydl_opts["concurrent_fragment_downloads"] = 5

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=True)

    post_id = info["id"]
    candidates = [f for f in CACHE_DIR.glob(f"{post_id}.*") if "_out" not in f.name]
    if not candidates:
        raise FileNotFoundError(f"Downloaded file not found for post_id={post_id}")

    info["video_path"] = str(candidates[0])
    info["post_id"] = post_id
    return info

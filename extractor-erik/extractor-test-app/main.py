"""CLI: python main.py <reel_url>"""
import json
import sys
from pathlib import Path

# Resolve extractor package from sibling directory
sys.path.insert(0, str(Path(__file__).parent.parent))

from extractor import cache_db, downloader, transcoder, gemini, places as places_module
from extractor import config

APP_DIR = Path(__file__).parent
cache_db.DB_PATH = APP_DIR / "places.db"
downloader.CACHE_DIR = APP_DIR / "cache"


def run(url: str) -> list:
    cache_db.init_schema()

    if config.REEL_CACHE_ENABLED:
        import yt_dlp
        with yt_dlp.YoutubeDL({"quiet": True, "skip_download": True}) as ydl:
            probe = ydl.extract_info(url, download=False)
        post_id = probe["id"]
        reel = cache_db.get_reel(post_id)
        if reel:
            cache_db.update_views(post_id, probe.get("view_count") or 0)
            return cache_db.get_places_for_reel(post_id)

    print("[1/5] Downloading...")
    info = downloader.download(url)

    print("[2/5] Transcoding...")
    video_path = transcoder.transcode(info["video_path"])

    print("[3/5] Extracting places with Gemini...")
    extracted = gemini.extract_places(video_path, info)
    print(f"      {len(extracted)} place(s) found")

    print("[4/5] Resolving places via Google Places API...")
    resolved = places_module.resolve_all_places(extracted)

    print("[5/5] Storing in DB...")
    cache_db.store_reel(info["post_id"], url, info, resolved)

    return resolved


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python main.py <reel_url>")
        sys.exit(1)
    result = run(sys.argv[1])
    print("\n=== Result ===")
    print(json.dumps(result, indent=2, ensure_ascii=False))

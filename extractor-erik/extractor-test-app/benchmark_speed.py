"""
Speed benchmark — runs the pipeline on 3 reels under 4 optimisation configurations.
All caching disabled. 10s sleep between each pipeline run.

Usage: python3 benchmark_speed.py
"""
import os
import sys
import time
import json
import re
from pathlib import Path

APP_DIR = Path(__file__).parent
sys.path.insert(0, str(APP_DIR.parent))

from extractor import cache_db, downloader, transcoder
from extractor import gemini as gemini_module
from extractor import places as places_module
import extractor.config as config

cache_db.DB_PATH = APP_DIR / "places.db"
downloader.CACHE_DIR = APP_DIR / "cache"

URLS = [
    "https://www.instagram.com/reel/DTpr7JzDaNF/",
    "https://www.instagram.com/reel/DW4EnUbjALF/",
    "https://www.instagram.com/reel/DWgFaJ3gv3_/",
]

CONFIGS = [
    {"label": "baseline",    "concurrent": False, "lowqual": False, "single": False},
    {"label": "A: fragments","concurrent": True,  "lowqual": False, "single": False},
    {"label": "A+B: 480p",  "concurrent": True,  "lowqual": True,  "single": False},
    {"label": "A+B+C: all", "concurrent": True,  "lowqual": True,  "single": True},
]

SLEEP_BETWEEN_RUNS = 3


def _post_id(url):
    return re.search(r"/reel/([A-Za-z0-9_-]+)", url).group(1)


def _clean(url):
    for f in (APP_DIR / "cache").glob(f"{_post_id(url)}*"):
        f.unlink(missing_ok=True)


def _apply(cfg):
    config.CONCURRENT_FRAGMENTS = cfg["concurrent"]
    config.LOW_QUALITY_DOWNLOAD = cfg["lowqual"]
    config.SINGLE_CALL_PLACES   = cfg["single"]


def run_timed(url):
    cache_db.init_schema()
    t = {}
    wall = time.perf_counter()
    t0 = time.perf_counter(); info = downloader.download(url);                              t["download"]  = time.perf_counter() - t0
    t0 = time.perf_counter(); vp   = transcoder.transcode(info["video_path"]);              t["transcode"] = time.perf_counter() - t0
    t0 = time.perf_counter(); ext  = gemini_module.extract_places(vp, info);               t["gemini"]    = time.perf_counter() - t0
    t0 = time.perf_counter(); _    = places_module.resolve_all_places(ext, False);         t["places"]    = time.perf_counter() - t0
    t["total"] = time.perf_counter() - wall
    return {
        "timings": t,
        "dl_mb": round(Path(info["video_path"]).stat().st_size / 1e6, 1),
        "tc_mb": round(Path(vp).stat().st_size / 1e6, 2),
        "n_places": len(ext),
        "places": ext,
    }


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("config", nargs="?", help="Run only this config label (e.g. baseline)")
    args = parser.parse_args()

    configs = CONFIGS
    if args.config:
        configs = [c for c in CONFIGS if c["label"] == args.config]
        if not configs:
            print(f"Unknown config '{args.config}'. Choose from: {[c['label'] for c in CONFIGS]}")
            sys.exit(1)

    results = {}
    total_runs = len(configs) * len(URLS)
    run_num = 0

    for cfg in configs:
        _apply(cfg)
        print(f"\n{'='*60}\nCONFIG: {cfg['label']}\n{'='*60}")
        per_url = []
        for url in URLS:
            run_num += 1
            _clean(url)
            if run_num > 1:
                print(f"  sleeping {SLEEP_BETWEEN_RUNS}s...")
                time.sleep(SLEEP_BETWEEN_RUNS)
            pid = _post_id(url)
            print(f"\n  [{run_num}/{total_runs}] {pid}")
            try:
                r = run_timed(url)
                per_url.append({"url": url, **r})
                t = r["timings"]
                print(f"    download  {t['download']:5.1f}s  ({r['dl_mb']} MB raw → {r['tc_mb']} MB transcoded)")
                print(f"    transcode {t['transcode']:5.1f}s")
                print(f"    gemini    {t['gemini']:5.1f}s  ({r['n_places']} places)")
                print(f"    places    {t['places']:5.1f}s")
                print(f"    TOTAL     {t['total']:5.1f}s")
            except Exception as e:
                per_url.append({"url": url, "error": str(e)})
                print(f"    ERROR: {e}")
        results[cfg["label"]] = per_url

    steps = ["download", "transcode", "gemini", "places", "total"]
    print(f"\n\n{'='*60}\nSUMMARY — avg timings per config\n{'='*60}")
    print(f"{'Config':<18}" + "".join(f"{s:>11}" for s in steps))
    print("-" * (18 + 11 * len(steps)))
    for cfg in CONFIGS:
        runs = [r for r in results[cfg["label"]] if "error" not in r]
        if not runs:
            print(f"{cfg['label']:<18}  (all failed)")
            continue
        avgs = {s: sum(r["timings"][s] for r in runs) / len(runs) for s in steps}
        print(f"{cfg['label']:<18}" + "".join(f"{avgs[s]:>10.1f}s" for s in steps))


if __name__ == "__main__":
    main()

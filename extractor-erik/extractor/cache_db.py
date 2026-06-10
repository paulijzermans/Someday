import sqlite3
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, List

# Callers (server.py, main.py) set this before calling init_schema()
DB_PATH = Path(__file__).parent.parent / "extractor-test-app" / "places.db"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def get_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_schema():
    with get_conn() as conn:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS reels (
                post_id          TEXT PRIMARY KEY,
                url              TEXT UNIQUE NOT NULL,
                title            TEXT,
                description      TEXT,
                uploader         TEXT,
                uploader_id      TEXT,
                posted_at        TEXT,
                views            INTEGER,
                views_updated_at TEXT,
                processed_at     TEXT
            );

            CREATE TABLE IF NOT EXISTS reel_places (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                post_id          TEXT NOT NULL REFERENCES reels(post_id),
                place_id         TEXT,
                gemini_name      TEXT,
                gemini_type      TEXT,
                gemini_detail    TEXT
            );

            CREATE TABLE IF NOT EXISTS places (
                place_id         TEXT PRIMARY KEY,
                display_name     TEXT,
                formatted_address TEXT,
                lat              REAL,
                lng              REAL,
                rating           REAL,
                rating_count     INTEGER,
                price_level      TEXT,
                phone            TEXT,
                website          TEXT,
                google_maps_uri  TEXT,
                primary_type     TEXT,
                business_status  TEXT,
                opening_hours    TEXT,
                fetched_at       TEXT
            );
        """)


def get_reel(post_id: str) -> Optional[dict]:
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM reels WHERE post_id = ?", (post_id,)).fetchone()
        return dict(row) if row else None


def update_views(post_id: str, views: int):
    with get_conn() as conn:
        conn.execute(
            "UPDATE reels SET views = ?, views_updated_at = ? WHERE post_id = ?",
            (views, _now(), post_id),
        )


def store_reel(post_id: str, url: str, info: dict, places: list):
    now = _now()
    with get_conn() as conn:
        conn.execute(
            """INSERT INTO reels
               (post_id, url, title, description, uploader, uploader_id,
                posted_at, views, views_updated_at, processed_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(post_id) DO UPDATE SET
                 title=excluded.title, description=excluded.description,
                 uploader=excluded.uploader, uploader_id=excluded.uploader_id,
                 posted_at=excluded.posted_at, views=excluded.views,
                 views_updated_at=excluded.views_updated_at,
                 processed_at=excluded.processed_at""",
            (
                post_id, url,
                info.get("title"), info.get("description"),
                info.get("uploader"), info.get("uploader_id"),
                datetime.fromtimestamp(info["timestamp"], tz=timezone.utc).isoformat()
                if info.get("timestamp") else None,
                info.get("view_count"), now, now,
            ),
        )
        conn.execute("DELETE FROM reel_places WHERE post_id = ?", (post_id,))
        for p in places:
            conn.execute(
                """INSERT INTO reel_places (post_id, place_id, gemini_name, gemini_type, gemini_detail)
                   VALUES (?, ?, ?, ?, ?)""",
                (post_id, p.get("place_id"), p.get("name"), p.get("type"), p.get("detail")),
            )


def get_places_for_reel(post_id: str) -> List[dict]:
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT rp.*, p.*
               FROM reel_places rp
               LEFT JOIN places p ON rp.place_id = p.place_id
               WHERE rp.post_id = ?""",
            (post_id,),
        ).fetchall()
        return [dict(r) for r in rows]


def get_place(place_id: str) -> Optional[dict]:
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM places WHERE place_id = ?", (place_id,)).fetchone()
        return dict(row) if row else None


def store_place(place_id: str, details: dict):
    with get_conn() as conn:
        conn.execute(
            """INSERT INTO places
               (place_id, display_name, formatted_address, lat, lng, rating,
                rating_count, price_level, phone, website, google_maps_uri,
                primary_type, business_status, opening_hours, fetched_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(place_id) DO UPDATE SET
                 display_name=excluded.display_name,
                 formatted_address=excluded.formatted_address,
                 lat=excluded.lat, lng=excluded.lng,
                 rating=excluded.rating, rating_count=excluded.rating_count,
                 price_level=excluded.price_level, phone=excluded.phone,
                 website=excluded.website, google_maps_uri=excluded.google_maps_uri,
                 primary_type=excluded.primary_type, business_status=excluded.business_status,
                 opening_hours=excluded.opening_hours, fetched_at=excluded.fetched_at""",
            (
                place_id,
                details.get("display_name"), details.get("formatted_address"),
                details.get("lat"), details.get("lng"),
                details.get("rating"), details.get("rating_count"),
                details.get("price_level"), details.get("phone"),
                details.get("website"), details.get("google_maps_uri"),
                details.get("primary_type"), details.get("business_status"),
                json.dumps(details.get("opening_hours")) if details.get("opening_hours") else None,
                _now(),
            ),
        )

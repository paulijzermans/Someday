import json
import os
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional

import requests
from dotenv import load_dotenv, find_dotenv

from . import cache_db, config

load_dotenv(find_dotenv())

PLACES_SEARCH_URL = "https://places.googleapis.com/v1/places:searchText"
PLACES_DETAILS_URL = "https://places.googleapis.com/v1/places/{place_id}"

FULL_FIELD_MASK = (
    "id,displayName,formattedAddress,location,"
    "rating,userRatingCount,regularOpeningHours,"
    "nationalPhoneNumber,websiteUri,priceLevel,"
    "primaryType,businessStatus,googleMapsUri"
)

db_write_lock = threading.Lock()


def _api_key() -> str:
    key = os.environ.get("GOOGLE_PLACES_API_KEY")
    if not key:
        raise RuntimeError("GOOGLE_PLACES_API_KEY not set in environment")
    return key


def _normalise(data: dict, place_id: str) -> dict:
    location = data.get("location") or {}
    return {
        "place_id": data.get("id", place_id),
        "display_name": (data.get("displayName") or {}).get("text"),
        "formatted_address": data.get("formattedAddress"),
        "lat": location.get("latitude"),
        "lng": location.get("longitude"),
        "rating": data.get("rating"),
        "rating_count": data.get("userRatingCount"),
        "price_level": data.get("priceLevel"),
        "phone": data.get("nationalPhoneNumber"),
        "website": data.get("websiteUri"),
        "google_maps_uri": data.get("googleMapsUri"),
        "primary_type": data.get("primaryType"),
        "business_status": data.get("businessStatus"),
        "opening_hours": data.get("regularOpeningHours"),
    }


def _confidence_ok(query: str, returned_name: str) -> bool:
    query_tokens = {t.lower() for t in query.split() if len(t) > 2}
    return any(token in returned_name.lower() for token in query_tokens)


def text_search_full(query: str) -> Optional[dict]:
    """Single Text Search call returning all needed place fields."""
    field_mask = "places." + FULL_FIELD_MASK.replace(",", ",places.")
    headers = {
        "X-Goog-Api-Key": _api_key(),
        "X-Goog-FieldMask": field_mask,
        "Content-Type": "application/json",
    }
    resp = requests.post(PLACES_SEARCH_URL, json={"textQuery": query}, headers=headers, timeout=10)
    resp.raise_for_status()
    candidates = resp.json().get("places", [])
    if not candidates:
        return None
    top = candidates[0]
    returned_name = (top.get("displayName") or {}).get("text", "")
    if not _confidence_ok(query, returned_name):
        return None
    return _normalise(top, top.get("id", ""))


def text_search_id_only(query: str) -> Optional[str]:
    """Text Search returning only place_id (free Essentials SKU)."""
    headers = {
        "X-Goog-Api-Key": _api_key(),
        "X-Goog-FieldMask": "places.id,places.displayName",
        "Content-Type": "application/json",
    }
    resp = requests.post(PLACES_SEARCH_URL, json={"textQuery": query}, headers=headers, timeout=10)
    resp.raise_for_status()
    candidates = resp.json().get("places", [])
    if not candidates:
        return None
    top = candidates[0]
    returned_name = (top.get("displayName") or {}).get("text", "")
    if not _confidence_ok(query, returned_name):
        return None
    return top.get("id")


def place_details(place_id: str) -> dict:
    """Fetch Place Details (separate call, baseline two-call path)."""
    headers = {
        "X-Goog-Api-Key": _api_key(),
        "X-Goog-FieldMask": FULL_FIELD_MASK,
    }
    resp = requests.get(PLACES_DETAILS_URL.format(place_id=place_id), headers=headers, timeout=10)
    resp.raise_for_status()
    return _normalise(resp.json(), place_id)


def resolve_place(name: str, detail: str, use_place_cache: bool = True) -> dict:
    query = f"{name} {detail}".strip()

    if config.SINGLE_CALL_PLACES:
        # One Text Search call returns place_id + all details — always 1 API call.
        details = text_search_full(query)
        if not details:
            return {"place_id": None}
        place_id = details["place_id"]
        if use_place_cache:
            cached = cache_db.get_place(place_id)
            if cached:
                return {**cached, "from_cache": True}
        with db_write_lock:
            cache_db.store_place(place_id, details)
        return {**details, "from_cache": False}
    else:
        # Baseline two-call path: ID-only (free) → cache check → details
        place_id = text_search_id_only(query)
        if not place_id:
            return {"place_id": None}
        if use_place_cache:
            cached = cache_db.get_place(place_id)
            if cached:
                return {**cached, "from_cache": True}
        details = place_details(place_id)
        with db_write_lock:
            cache_db.store_place(place_id, details)
        return {**details, "from_cache": False}


def resolve_all_places(extracted: list, use_place_cache: bool = True) -> list:
    """Resolve all extracted places in parallel (ThreadPoolExecutor, max 20 workers)."""
    with ThreadPoolExecutor(max_workers=20) as executor:
        futures = {
            executor.submit(resolve_place, p.get("name", ""), p.get("detail", ""), use_place_cache): p
            for p in extracted
        }
        results = []
        for future in as_completed(futures):
            gemini_place = futures[future]
            try:
                resolved = future.result()
            except Exception as e:
                print(f"[places] resolution failed for {gemini_place.get('name')}: {e}")
                resolved = {"place_id": None}
            results.append({**gemini_place, **resolved})
    return results

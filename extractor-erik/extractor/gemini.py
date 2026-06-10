import json
import os
from dotenv import load_dotenv, find_dotenv
from google import genai
from google.genai import types

load_dotenv(find_dotenv())

MODEL = "gemini-3.1-flash-lite"

SYSTEM_PROMPT = (
    "You are extracting place mentions from an Instagram Reel. "
    "Return ONLY a valid JSON array, no preamble, no markdown fences."
)

USER_PROMPT_TEMPLATE = """\
Below is metadata for this Instagram Reel:
- Title: {title}
- Caption/description: {description}
- Posted by: {uploader}

Watch the reel and extract every place mentioned via voiceover OR visible text overlay.
Use the metadata above as additional context — place names or addresses sometimes appear
in the caption even if not spoken or shown clearly in the video.

Return this exact structure:
[
  {{
    "name": "full place name as mentioned or shown",
    "type": "restaurant | bar | cafe | shop | other",
    "detail": "any extra context: address, neighbourhood, city, rating, price range"
  }}
]

Rules:
- If city is spoken, shown, or inferable from the caption, always include it in detail
- Include partial info if that is all that is available
- Do not infer or hallucinate — only include what is explicitly mentioned or visible
- Do not extract generic locations like cities, countries, or neighbourhoods — only specific venues (restaurants, bars, cafes, shops, attractions, etc.)
"""

RETRY_SUFFIX = "\nYour previous response was not valid JSON. Return only the raw JSON array, nothing else."


def _client() -> genai.Client:
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        raise RuntimeError("GEMINI_API_KEY not set in environment")
    return genai.Client(api_key=api_key)


def _call(client: genai.Client, video_bytes: bytes, prompt: str) -> str:
    response = client.models.generate_content(
        model=MODEL,
        contents=[
            types.Part.from_bytes(data=video_bytes, mime_type="video/mp4"),
            prompt,
        ],
        config=types.GenerateContentConfig(
            system_instruction=SYSTEM_PROMPT,
            thinking_config=types.ThinkingConfig(thinking_budget=0),
            media_resolution=types.MediaResolution.MEDIA_RESOLUTION_LOW,
        ),
    )
    return response.text.strip()


def extract_places(video_path: str, info: dict) -> list:
    """Read transcoded video and return list of extracted place dicts."""
    with open(video_path, "rb") as f:
        video_bytes = f.read()

    prompt = USER_PROMPT_TEMPLATE.format(
        title=info.get("title") or "",
        description=info.get("description") or "",
        uploader=info.get("uploader") or "",
    )

    client = _client()
    raw = _call(client, video_bytes, prompt)

    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        raw2 = _call(client, video_bytes, prompt + RETRY_SUFFIX)
        try:
            return json.loads(raw2)
        except json.JSONDecodeError:
            raise RuntimeError(f"Gemini returned invalid JSON after retry:\n{raw2}")

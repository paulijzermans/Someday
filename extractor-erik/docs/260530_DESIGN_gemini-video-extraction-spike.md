# Gemini Video Extraction — Spike Resultaten

**Datum:** 2026-05-30  
**Doel:** Valideren of Gemini plaatsnamen betrouwbaar uit korte social video's kan extraheren, en welke pipeline configuratie het snelst en goedkoopst is.

---

## Wat getest

- 21s Bangkok rooftop bar video (IG Reel-formaat, 720×1280)
- 6 configuraties: variaties in compressie, upload methode, en thinking budget
- Model: `gemini-3.1-flash-lite`
- Elk getest met 2 runs voor variantie

---

## Aanbeveling implementatie

**Setup:**
```python
from google import genai
from google.genai import types

client = genai.Client(api_key=GEMINI_API_KEY)

with open(video_path, "rb") as f:
    video_bytes = f.read()

response = client.models.generate_content(
    model="gemini-3.1-flash-lite",
    contents=[
        types.Part.from_bytes(data=video_bytes, mime_type="video/mp4"),
        PROMPT,
    ],
    config=types.GenerateContentConfig(
        thinking_config=types.ThinkingConfig(thinking_budget=0),
        media_resolution=types.MediaResolution.MEDIA_RESOLUTION_LOW,
    ),
)
```

**Prompt:**
```
Watch this video and extract all places that are recommended.

Return a JSON array where each item has:
- "name": the place name exactly as mentioned in the video
- "city": the city where this place is located, based on what you see or hear in the video
- "country": the country where this place is located, based on what you see or hear in the video
- "reason": the reason why this place is recommended, ONLY if explicitly stated in the video's text or audio. Do not infer. Set to null if not mentioned.

Return ONLY valid JSON, no other text. If no places are found, return [].
```

**Keuzes en waarom:**

| Keuze | Waarde | Reden |
|-------|--------|-------|
| Upload methode | Inline base64 (geen File API) | File API vereist upload + polling op ACTIVE state — voegt 10-30s toe. Inline is één request, ~3s totaal. |
| Compressie | Geen | Audio intact houden is belangrijk (plaatsnamen worden vaak uitgesproken). Compressie gaf geen meetbare snelheidswinst op dit formaat. |
| Thinking budget | 0 (uit) | Thinking voegt latency toe (tot 2x) zonder kwaliteitswinst op deze taak. De extractie is eenvoudig genoeg. |
| Media resolution | LOW | Reduceert video tokens van ~23.500 naar ~1.915 (12x minder). Kwaliteit van extractie identiek. |
| Model | gemini-3.1-flash-lite | Betrouwbaar, snel, goedkoop. Alle 12 test-runs slaagden (5/5 plaatsen, juiste stad/land). |

---

## Benchmark samenvatting

Alle 6 configuraties gaven identieke kwaliteit (12/12 runs correct). Snelheid was het verschil:

| Config | Gem. tijd | Bestandsgrootte |
|--------|-----------|-----------------|
| Original + thinking=OFF + media_res=LOW | **~3s** | 6 MB |
| 360p/5fps + thinking=OFF | ~2.8s | 1.8 MB |
| 360p/1fps + thinking=OFF | ~2.9s | 0.8 MB |
| Original + thinking=LOW(1024) | ~4.4s | 6 MB |
| 360p/5fps + thinking=FULL | ~3.6s | 1.8 MB |

Conclusie: thinking uitschakelen heeft de meeste impact. Compressie helpt op schaal (kosten/bandbreedte) maar niet op latency voor korte clips.

---

## Kosten

**Per call (21s video, media_resolution=LOW):**
- Input: 1.955 tokens × $0.25/1M = $0.00049
- Output: 209 tokens × $1.50/1M = $0.00031
- **Totaal: ~$0.0008 per video**

**Op schaal:** 10.000 video's ≈ $8 | 100.000 video's ≈ $80

---

## Volgende stappen

### 1. Places IDs toevoegen
Google Maps grounding (via de Gemini API) bleek niet geschikt voor video-extractie — het triggert alleen bij "wat is er bij mij in de buurt"-queries, niet bij het extraheren van entiteiten uit video. Aanbeveling: **twee-stap pipeline**:
1. Gemini extraheert naam + stad + land uit video (huidige setup)
2. Google Places Text Search API resolvet elke naam naar een `place_id`
   - Endpoint: `https://places.googleapis.com/v1/places:searchText`
   - Goedkoop: ~$0.017 per call
   - Stuur naam + stad mee als query voor hoge trefkans (bijv. `"Tichuca Rooftop Bangkok"`)

### 2. Video acquisition — TikTok & Instagram Reels
De video moet als MP4 server-side beschikbaar zijn vóór de Gemini call. Opties:

**Managed scraper (aanbevolen voor MVP):**  
Apify of ScrapeCreators. Geef een post-URL, krijg een MP4 download-link terug. Zie ingestion pipeline design doc voor details. Voordeel: geen infrastructure, geen ban-risico. Nadeel: kosten per call (~$0.001–0.005/video) en latency (~5–15s).

**Latency risico:** Een managed scraper + Gemini call samen kan 10–20s duren per video. Dat is acceptabel voor een async pipeline maar niet voor real-time. Aanbeveling: verwerk video's asynchroon (job queue), sla resultaten op in DB, toon aan gebruiker zodra klaar.

**Metadata (caption, auteur):**  
Scraper levert caption + auteur mee als tekst. Stuur dit als extra tekstdeel mee in de Gemini request — kan helpen bij het identificeren van plaatsnamen die alleen in de caption staan en niet in de video zelf.

### 3. Video re-encoding
Sommige video's van scrapers hebben audio-incompatibiliteit. Fix bij binnenkomst:
```bash
ffmpeg -i input.mp4 -c:v libx264 -c:a aac -movflags +faststart output.mp4
```
Alleen nodig als de scraper geen schone MP4 levert — valideer eerst met ffprobe.

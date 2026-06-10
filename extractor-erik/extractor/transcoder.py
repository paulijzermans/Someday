import subprocess
from pathlib import Path


def transcode(video_path: str) -> str:
    """Transcode to 1fps / 360p wide, keep audio. Returns output path.

    Design choices:
    - -skip_frame noref: skip B-frame decode — ~30% fewer frames decoded, no quality loss at 1fps
    - -t 60: cap at 60s; places are always mentioned in the first half of any reel
    - fps=1: captures text overlays (stay on screen 2-5s) with minimal data
    - scale=360:-2: fixed 360px wide, height auto-calculated (portrait reels → ~360x640)
    - libx264 -crf 40 -preset ultrafast: software encoder
    - 32kbps mono 16kHz audio: sufficient for voiceover/speech recognition by Gemini
    Result: ~8x file size reduction vs source (avg 16MB → 1MB)
    """
    src = Path(video_path)
    out = src.parent / f"{src.stem}_out.mp4"

    if out.exists():
        return str(out)

    cmd = [
        "ffmpeg", "-y", "-skip_frame", "noref",
        "-i", str(src),
        "-t", "60",
        "-vf", "fps=1,scale=360:-2:flags=fast_bilinear",
        "-c:v", "libx264", "-crf", "40", "-preset", "ultrafast",
        "-b:a", "32k", "-ac", "1", "-ar", "16000",
        str(out),
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg failed:\n{result.stderr}")

    size_mb = out.stat().st_size / 1_000_000
    if size_mb > 20:
        raise RuntimeError(f"Transcoded file is {size_mb:.1f}MB — exceeds 20MB inline limit")

    return str(out)

"""
Render teardrop pin variants for Someday so we can pick an edge treatment
before changing ClusteredMapView. Each row is a category color; columns
show different edge styles + an optional centered emoji.

Output: design/pin-logos/pins.png
"""
from __future__ import annotations
import math
import matplotlib.pyplot as plt
from matplotlib.patches import Circle, FancyBboxPatch, Polygon
from matplotlib.path import Path
import matplotlib.patches as mpatches
import numpy as np


# Category palette mirrors SomedayColors so the preview matches the app.
CATEGORIES = [
    ("Food",     "#4272FF", "🍽️"),
    ("Drinks",   "#FF7E42", "🍸"),
    ("Coffee",   "#FFB343", "☕"),
    ("Activity", "#33BB66", "🥾"),
    ("Art",      "#8A5BFF", "🎨"),
]

# Variants for the edge treatment.
VARIANTS = [
    "current",         # baseline: solid outer ring, no extras
    "soft-edge",       # thinner outer outline + inner highlight crescent
    "soft-edge-emoji", # same as soft-edge plus a centered emoji
]


def _teardrop_path(center, radius=1.0, tip_drop=1.6):
    """Build a teardrop polygon matching the in-app pin geometry."""
    cx, cy = center
    L = tip_drop
    r = radius
    # Tangent angle from the tip back to the circle:
    beta = math.acos(max(-1.0, min(1.0, r / L)))
    right_angle = math.pi / 2 - beta
    left_angle = math.pi / 2 + beta

    tip = (cx, cy - L)
    pts = [tip]
    # Arc across the top of the bulb (going counter-clockwise from right tangent).
    n = 60
    # angle sweeps from right_angle up across the top to left_angle (measured from +x).
    for i in range(n + 1):
        t = right_angle + (left_angle - right_angle) * i / n
        # arc above the bulb center: y goes up as sin grows
        x = cx + r * math.cos(t)
        y = cy + r * math.sin(t)
        pts.append((x, y))
    pts.append(tip)
    return pts


def draw_pin(ax, *, color: str, variant: str, emoji: str | None, x_offset: float):
    """Draw a single pin onto `ax` at `(x_offset, 0)`."""
    center = (x_offset, 0.4)
    r = 0.55
    L = 1.05

    pts = _teardrop_path(center, radius=r, tip_drop=L)

    if variant == "current":
        # Solid colored fill + crisp white outline.
        outer = Polygon(pts, closed=True, facecolor="white", edgecolor="none", zorder=1)
        ax.add_patch(outer)
        inner_pts = _teardrop_path(center, radius=r - 0.07, tip_drop=L - 0.10)
        inner = Polygon(inner_pts, closed=True, facecolor=color, edgecolor="none", zorder=2)
        ax.add_patch(inner)

    elif variant in {"soft-edge", "soft-edge-emoji"}:
        # Subtle outer shadow (drop), refined outline, then fill with a top highlight.
        # Drop shadow: same shape shifted slightly down.
        shadow_pts = _teardrop_path((center[0], center[1] - 0.06), radius=r, tip_drop=L)
        ax.add_patch(Polygon(shadow_pts, closed=True, facecolor=(0, 0, 0, 0.18), edgecolor="none", zorder=0))

        # Crisp white border.
        ax.add_patch(Polygon(pts, closed=True, facecolor="white", edgecolor="none", zorder=1))

        # Colored body, slightly inset.
        inner_pts = _teardrop_path(center, radius=r - 0.05, tip_drop=L - 0.07)
        body = Polygon(inner_pts, closed=True, facecolor=color, edgecolor="none", zorder=2)
        ax.add_patch(body)

        # Top highlight crescent — soft white glow on the upper-left of the bulb.
        crescent = Circle(
            (center[0] - r * 0.28, center[1] + r * 0.30),
            r * 0.45,
            facecolor=(1, 1, 1, 0.30),
            edgecolor="none",
            zorder=3,
        )
        ax.add_patch(crescent)

        if variant == "soft-edge-emoji" and emoji:
            ax.text(
                center[0], center[1],
                emoji,
                ha="center", va="center",
                fontsize=22,
                zorder=4,
                fontfamily="Apple Color Emoji" if _has_emoji_font() else None,
            )

    # Common: tiny shadow at the very tip to anchor the pin.
    ax.add_patch(Circle((center[0], center[1] - L + 0.02), 0.08, facecolor=(0, 0, 0, 0.18), edgecolor="none", zorder=0))


def _has_emoji_font() -> bool:
    """Best-effort detection of the system Apple Color Emoji font."""
    from matplotlib import font_manager
    return any("Apple Color Emoji" in f.name for f in font_manager.fontManager.ttflist)


def render(path: str):
    rows = len(CATEGORIES)
    cols = len(VARIANTS)
    fig, axes = plt.subplots(rows, cols, figsize=(cols * 2.6, rows * 2.0), dpi=150, facecolor="white")
    for r_idx, (name, color, emoji) in enumerate(CATEGORIES):
        for c_idx, variant in enumerate(VARIANTS):
            ax = axes[r_idx][c_idx]
            ax.set_xlim(-1.0, 1.0)
            ax.set_ylim(-1.0, 1.2)
            ax.set_aspect("equal")
            ax.axis("off")
            draw_pin(ax, color=color, variant=variant, emoji=emoji, x_offset=0)
            if r_idx == 0:
                ax.set_title(variant.replace("-", " ").title(), fontsize=12, weight="bold", pad=8, color="#0F1B33")
            if c_idx == 0:
                ax.text(-1.2, 0.4, name, ha="right", va="center", fontsize=11, weight="bold", color="#0F1B33")
    fig.subplots_adjust(left=0.06, right=0.99, top=0.94, bottom=0.02, wspace=0, hspace=0)
    fig.savefig(path, dpi=150, facecolor="white", bbox_inches="tight")
    plt.close(fig)


if __name__ == "__main__":
    out = "design/pin-logos/pins.png"
    render(out)
    print("Wrote", out)

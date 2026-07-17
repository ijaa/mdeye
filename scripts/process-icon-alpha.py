#!/usr/bin/env python3
"""Convert a rounded logo (often JPEG with black outside corners) into a
transparent PNG suitable for macOS AppIcon.icns generation.

JPEG cannot store alpha, so rounded exports usually fill the exterior with black.
macOS then shows those pixels as a black frame around the squircle.
"""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image
import numpy as np


def black_to_alpha(img: Image.Image, floor: float = 8.0, full: float = 36.0) -> Image.Image:
    """Soft-key pure/near-black background to transparency.

    Logo artwork is light (white/pastel); black only appears in the exterior fill
    and anti-aliased rim — map those to alpha.
    """
    rgba = img.convert("RGBA")
    arr = np.array(rgba, dtype=np.float32)
    # Use max channel so near-black grays become translucent smoothly
    brightness = arr[:, :, :3].max(axis=2)
    # brightness <= floor -> alpha 0; >= full -> alpha 255
    alpha = np.clip((brightness - floor) * (255.0 / max(full - floor, 1.0)), 0, 255)
    # Keep original alpha if source already had transparency (min)
    orig_a = arr[:, :, 3]
    arr[:, :, 3] = np.minimum(orig_a, alpha)
    return Image.fromarray(arr.astype(np.uint8), "RGBA")


def apply_squircle_mask(img: Image.Image, radius_ratio: float = 0.2237) -> Image.Image:
    """Optional extra macOS-like continuous corner mask (superellipse approx via roundrect)."""
    w, h = img.size
    r = int(min(w, h) * radius_ratio)
    # Build soft round-rect mask
    mask = Image.new("L", (w, h), 0)
    from PIL import ImageDraw

    draw = ImageDraw.Draw(mask)
    # slightly inset to avoid 1px fringe
    inset = max(1, int(min(w, h) * 0.002))
    draw.rounded_rectangle(
        (inset, inset, w - 1 - inset, h - 1 - inset),
        radius=max(r - inset, 1),
        fill=255,
    )
    # Soften mask edge
    mask = mask.filter(__import__("PIL.ImageFilter", fromlist=["GaussianBlur"]).GaussianBlur(radius=max(1, min(w, h) // 400)))
    out = img.convert("RGBA")
    out.putalpha(ImageChops_multiply_alpha(out.getchannel("A"), mask))
    return out


def ImageChops_multiply_alpha(a: Image.Image, b: Image.Image) -> Image.Image:
    aa = np.array(a, dtype=np.uint16)
    bb = np.array(b, dtype=np.uint16)
    return Image.fromarray(((aa * bb) // 255).astype(np.uint8), "L")


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: process-icon-alpha.py <input> <output.png>", file=sys.stderr)
        return 2
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    img = Image.open(src)
    # Primary fix: black exterior -> transparent
    img = black_to_alpha(img)
    # Tighten to squircle so residual fringe is clipped
    img = apply_squircle_mask(img)
    # Ensure even square
    w, h = img.size
    side = min(w, h)
    if w != h:
        left = (w - side) // 2
        top = (h - side) // 2
        img = img.crop((left, top, left + side, top + side))
    # Normalize to 1024 for quality
    if img.size[0] != 1024:
        img = img.resize((1024, 1024), Image.Resampling.LANCZOS)
    dst.parent.mkdir(parents=True, exist_ok=True)
    img.save(dst, format="PNG")
    # Report corner alpha for sanity
    arr = np.array(img)
    print(
        "wrote",
        dst,
        "size",
        img.size,
        "corner_alpha",
        int(arr[0, 0, 3]),
        int(arr[0, -1, 3]),
        int(arr[-1, 0, 3]),
        int(arr[-1, -1, 3]),
        "center_alpha",
        int(arr[arr.shape[0] // 2, arr.shape[1] // 2, 3]),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

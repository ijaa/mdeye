#!/usr/bin/env python3
"""Generate optimized iconset from source PNG."""
import sys
from pathlib import Path
from PIL import Image

def main():
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} <source.png> <iconset-dir>")
        sys.exit(1)

    src = Path(sys.argv[1])
    iconset = Path(sys.argv[2])
    iconset.mkdir(parents=True, exist_ok=True)

    img = Image.open(src)
    if img.mode != 'RGBA':
        img = img.convert('RGBA')

    sizes = [
        (16, 'icon_16x16.png'),
        (32, 'icon_16x16@2x.png'),
        (32, 'icon_32x32.png'),
        (64, 'icon_32x32@2x.png'),
        (128, 'icon_128x128.png'),
        (256, 'icon_128x128@2x.png'),
        (256, 'icon_256x256.png'),
        (512, 'icon_256x256@2x.png'),
        (512, 'icon_512x512.png'),
        (1024, 'icon_512x512@2x.png'),
    ]

    for size, name in sizes:
        resized = img.resize((size, size), Image.Resampling.LANCZOS)
        out = iconset / name
        resized.save(out, 'PNG', optimize=True, compress_level=9)
        print(f"  {name} → {out.stat().st_size // 1024}KB")

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""
Measure face geometry out of a 1-bit/RGBA PNG frame sequence.

Used to derive ARCA Core's face proportions from the MIT-licensed Dasai Mochi
frame export (github.com/upiir/esp32s3_oled_dasai_mochi). Those frames are
128x64 1-bit, built for an SSD1306. Upscaling them 2.2x onto this board's
284x240 colour IPS looks soft and blocky, so instead we measure the shapes,
express them as fractions of the canvas, and redraw them as vectors in LVGL.
That stays sharp at any resolution and keeps the shipped default original.

Pure stdlib: no PIL. Decodes PNG by hand (zlib + the five filter types).

    python3 extract_face_geometry.py <dir-of-pngs> [frame ...]
"""

import glob
import os
import struct
import sys
import zlib


def decode_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", f"{path} is not a PNG"
    pos, idat, w, h, bd, ct = 8, b"", None, None, None, None
    while pos < len(d):
        ln = struct.unpack(">I", d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        data = d[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, bd, ct = struct.unpack(">IIBB", data[:10])
        elif typ == b"IDAT":
            idat += data
        pos += 12 + ln

    raw = zlib.decompress(idat)
    bpp_bits = {0: bd, 3: bd, 2: bd * 3, 4: bd * 2, 6: bd * 4}[ct]
    stride = (w * bpp_bits + 7) // 8
    fbpp = max(1, bpp_bits // 8)

    out, prev, i = bytearray(), bytearray(stride), 0
    for _ in range(h):
        ft = raw[i]; i += 1
        line = bytearray(raw[i:i + stride]); i += stride
        if ft == 1:
            for x in range(fbpp, stride):
                line[x] = (line[x] + line[x - fbpp]) & 255
        elif ft == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif ft == 3:
            for x in range(stride):
                a = line[x - fbpp] if x >= fbpp else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif ft == 4:
            for x in range(stride):
                a = line[x - fbpp] if x >= fbpp else 0
                b = prev[x]
                c = prev[x - fbpp] if x >= fbpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out += line
        prev = line

    grid = [[False] * w for _ in range(h)]
    for y in range(h):
        row = out[y * stride:(y + 1) * stride]
        for x in range(w):
            if bd == 1:
                grid[y][x] = ((row[x >> 3] >> (7 - (x & 7))) & 1) == 1
            elif ct == 3:
                grid[y][x] = row[x] != 0
            else:
                grid[y][x] = row[x * (bpp_bits // 8)] > 127
    return w, h, grid


def blobs(grid, w, h, min_px=4):
    seen = [[False] * w for _ in range(h)]
    found = []
    for y in range(h):
        for x in range(w):
            if not grid[y][x] or seen[y][x]:
                continue
            stack, comp = [(x, y)], []
            seen[y][x] = True
            while stack:
                cx, cy = stack.pop()
                comp.append((cx, cy))
                for dx in (-1, 0, 1):
                    for dy in (-1, 0, 1):
                        nx, ny = cx + dx, cy + dy
                        if 0 <= nx < w and 0 <= ny < h and grid[ny][nx] and not seen[ny][nx]:
                            seen[ny][nx] = True
                            stack.append((nx, ny))
            if len(comp) >= min_px:
                found.append(comp)
    return found


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    d = sys.argv[1]
    names = sys.argv[2:] or sorted(os.path.basename(p) for p in glob.glob(os.path.join(d, "*.png")))

    for name in names:
        path = os.path.join(d, name)
        w, h, grid = decode_png(path)
        shapes = sorted(blobs(grid, w, h), key=lambda c: min(p[0] for p in c))
        print(f"\n--- {name}  ({w}x{h}, {len(shapes)} shapes) ---")
        for c in shapes:
            xs = [p[0] for p in c]
            ys = [p[1] for p in c]
            x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
            print(f"  x {x0:3d}..{x1:3d}  y {y0:3d}..{y1:3d}   "
                  f"w={x1-x0+1:3d} h={y1-y0+1:3d}  px={len(c):4d}   "
                  f"frac: x {x0/w:.3f}-{x1/w:.3f}  y {y0/h:.3f}-{y1/h:.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

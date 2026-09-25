#!/usr/bin/env python3
"""Draw the three drivers' icons as PNGs with no third-party libraries.

Each icon is described as a few shapes in a 0..1 coordinate space and rasterised with 4x4
supersampling, so the same drawing produces clean 16/32/70/90/300 px files.
Writes <driver>/www/icons/device_sm.png (16), device_lg.png (32) and device/<size>.png.
"""
import os
import struct
import zlib

INK = (40, 44, 52, 255)
BEAM = (255, 196, 64, 170)
ACCENT = (70, 140, 230, 255)


def png(path, w, h, pixels):
    raw = b''.join(b'\x00' + bytes(sum((list(p) for p in pixels[y * w:(y + 1) * w]), [])) for y in range(h))

    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 9)))
        f.write(chunk(b'IEND', b''))


def rect(x0, y0, x1, y1):
    return lambda x, y: x0 <= x <= x1 and y0 <= y <= y1


def circle(cx, cy, r):
    return lambda x, y: (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def poly(pts):
    def inside(x, y):
        n, c = len(pts), False
        j = n - 1
        for i in range(n):
            xi, yi = pts[i]
            xj, yj = pts[j]
            if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
                c = not c
            j = i
        return c
    return inside


def render(shapes, size):
    ss = 4
    out = []
    for py in range(size):
        for px in range(size):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sy in range(ss):
                for sx in range(ss):
                    x = (px + (sx + 0.5) / ss) / size
                    y = (py + (sy + 0.5) / ss) / size
                    col = (0, 0, 0, 0)
                    for test, c in shapes:          # later shapes paint over earlier ones
                        if test(x, y):
                            a = c[3] / 255
                            col = tuple(col[i] * (1 - a) + c[i] * a for i in range(3)) + (max(col[3], c[3]),)
                    for i in range(4):
                        acc[i] += col[i]
            out.append(tuple(int(round(v / (ss * ss))) for v in acc))
    return out


ICONS = {
    # A node: a box with an Ethernet jack on one side and a DMX (XLR) socket on the other.
    'artnet_node': [
        (rect(0.08, 0.28, 0.92, 0.72), INK),
        (rect(0.16, 0.40, 0.36, 0.60), ACCENT),
        (circle(0.70, 0.50, 0.12), (230, 232, 236, 255)),
        (circle(0.65, 0.47, 0.025), INK), (circle(0.75, 0.47, 0.025), INK), (circle(0.70, 0.55, 0.025), INK),
    ],
    # A par can throwing a beam.
    'dmx_light': [
        (poly([(0.52, 0.30), (0.98, 0.10), (0.98, 0.90), (0.52, 0.70)]), BEAM),
        (rect(0.10, 0.28, 0.56, 0.72), INK),
        (rect(0.02, 0.44, 0.12, 0.56), INK),
        (circle(0.33, 0.50, 0.12), ACCENT),
    ],
    # A moving head: base, yoke, tilted head with a beam.
    'dmx_mover': [
        (poly([(0.55, 0.30), (0.98, 0.02), (0.98, 0.45), (0.62, 0.52)]), BEAM),
        (rect(0.18, 0.82, 0.82, 0.96), INK),
        (rect(0.46, 0.70, 0.54, 0.84), INK),
        (rect(0.18, 0.64, 0.82, 0.72), INK),
        (rect(0.18, 0.30, 0.26, 0.70), INK), (rect(0.74, 0.30, 0.82, 0.70), INK),
        (circle(0.50, 0.44, 0.20), INK),
        (circle(0.56, 0.40, 0.08), ACCENT),
    ],
}

if __name__ == '__main__':
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for driver, shapes in ICONS.items():
        base = os.path.join(root, driver, 'www', 'icons')
        for name, size in (('device_sm.png', 16), ('device_lg.png', 32)):
            png(os.path.join(base, name), size, size, render(shapes, size))
        for size in (70, 90, 300):
            png(os.path.join(base, 'device', 'experience_%d.png' % size), size, size, render(shapes, size))
        print('icons written for', driver)

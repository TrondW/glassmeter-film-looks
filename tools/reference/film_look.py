#!/usr/bin/env python3
"""Reference implementation of the GlassMeter film look, in plain Python.

Independent of the Swift package; used to produce profiles/test-vectors.json.
Port this (or the Swift FilmLookCube.Look) if you are not on Core Image.

All values are Display P3 encoded RGB (sRGB transfer function), 0..1.

    python3 tools/reference/film_look.py vectors      # rewrite test vectors
    python3 tools/reference/film_look.py show kodak-portra-400 0.5 0.4 0.3
"""
import json, struct, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
PROFILES = ROOT / "profiles" / "film-stocks.json"
PRINT_CONTRAST_SCALE = 1.85


def f32(v):
    """Round to IEEE float32 (the app builds its base cube in Float)."""
    return struct.unpack("f", struct.pack("f", v))[0]


def clamp(v):
    return 0.0 if v < 0 else 1.0 if v > 1 else v


def curve_table(points):
    """256-entry table, linear between 0-255 control points, flat outside."""
    pts = sorted(points)
    table = []
    for i in range(256):
        x = float(i)
        if x <= pts[0][0]:
            y = pts[0][1]
        elif x >= pts[-1][0]:
            y = pts[-1][1]
        else:
            for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
                if x0 <= x <= x1:
                    y = y0 + (x - x0) / (x1 - x0) * (y1 - y0)
                    break
        table.append(f32(y / 255.0))
    return table


class MonotoneCurve:
    """PCHIP interior slopes (weighted harmonic mean), secant slopes at the
    ends, cubic Hermite segments, input clamped to the first/last x."""

    def __init__(self, points):
        self.xs = [p[0] for p in points]
        self.ys = [p[1] for p in points]
        n = len(points)
        h = [self.xs[k + 1] - self.xs[k] for k in range(n - 1)]
        d = [(self.ys[k + 1] - self.ys[k]) / h[k] for k in range(n - 1)]
        m = [0.0] * n
        m[0], m[-1] = d[0], d[-1]
        for k in range(1, n - 1):
            if d[k - 1] * d[k] <= 0:
                m[k] = 0.0
            else:
                w1, w2 = 2 * h[k] + h[k - 1], h[k] + 2 * h[k - 1]
                m[k] = (w1 + w2) / (w1 / d[k - 1] + w2 / d[k])
        self.m = m

    def __call__(self, x):
        xs, ys, m = self.xs, self.ys, self.m
        x = min(max(x, xs[0]), xs[-1])
        k = 0
        while k < len(xs) - 2 and x > xs[k + 1]:
            k += 1
        h = xs[k + 1] - xs[k]
        t = (x - xs[k]) / h
        t2, t3 = t * t, t * t * t
        return ((2 * t3 - 3 * t2 + 1) * ys[k] + (t3 - 2 * t2 + t) * h * m[k]
                + (-2 * t3 + 3 * t2) * ys[k + 1] + (t3 - t2) * h * m[k + 1])


def characteristic_points(c):
    toe, ceiling, slope = c["toeLift"], 1.0 - c["shoulderCompression"], c["midtoneSlope"]
    lower = min(max(0.5 - 0.25 * slope, toe + 0.02), 0.45)
    upper = max(min(0.5 + 0.28 * slope, ceiling - 0.02), 0.55)
    return [(0.0, toe), (0.25, lower), (0.5, 0.5), (0.78, upper), (1.0, ceiling)]


def push_pull_points(stops):
    if stops == 0:
        return None
    s = float(stops)
    return [(0.0, 0.0), (0.25, clamp(0.25 - 0.03 * s)), (0.5, 0.5),
            (0.75, clamp(0.75 + 0.025 * s)), (1.0, 1.0)]


def make_look(film, push_pull_stops=0):
    look = film["look"]
    neutral = look["characteristicCurve"] is None
    mixer = look["channelMixer"] if look["channelMixer"] and len(look["channelMixer"]) == 9 else None
    ident = [[0, 0], [255, 255]]
    curves = look["curves"] or {"red": ident, "green": ident, "blue": ident}
    tables = [curve_table(curves[c]) for c in ("red", "green", "blue")]
    sat = look["saturation"]
    k = 1 + PRINT_CONTRAST_SCALE * look["contrast"]
    pp = push_pull_points(push_pull_stops)
    push = MonotoneCurve(pp) if pp else None
    char = MonotoneCurve(characteristic_points(look["characteristicCurve"])) if not neutral else None

    def apply(r, g, b):
        r, g, b = clamp(r), clamp(g), clamp(b)
        if not neutral:
            if mixer:                                   # 1. channel mixer
                m = mixer
                r, g, b = (clamp(r * m[0] + g * m[1] + b * m[2]),
                           clamp(r * m[3] + g * m[4] + b * m[5]),
                           clamp(r * m[6] + g * m[7] + b * m[8]))
            idx = lambda v: min(max(int(f32(f32(v) * 255.0)), 0), 255)
            r, g, b = tables[0][idx(r)], tables[1][idx(g)], tables[2][idx(b)]  # 2. curves
            if sat != 0:                                # 3. saturation
                lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                r, g, b = (lum + (v - lum) * (1 + sat) for v in (r, g, b))
            r, g, b = (clamp((v - 0.5) * k + 0.5) for v in (r, g, b))  # 4. print contrast
        if push:                                        # 5. push / pull
            r, g, b = push(r), push(g), push(b)
        if char:                                        # 6. characteristic curve
            r, g, b = char(r), char(g), char(b)
        return clamp(r), clamp(g), clamp(b)

    return apply


def load():
    return json.loads(PROFILES.read_text())["films"]


def probes():
    """5x5x5 grid plus 64 deterministic pseudo-random colors."""
    out = [(i % 5 / 4, (i // 5) % 5 / 4, (i // 25) / 4) for i in range(125)]
    seed = 20261010

    def nxt():
        nonlocal seed
        seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF
        return (seed >> 8) / float(1 << 24)

    out += [(nxt(), nxt(), nxt()) for _ in range(64)]
    return out


def write_vectors():
    films, pts = load(), probes()
    cases = []
    for stops in (0, 2, -1):
        outputs = {}
        for film in films:
            f = make_look(film, stops)
            outputs[film["id"]] = [round(v, 5) for p in pts for v in f(*p)]
        cases.append({"pushPullStops": stops, "outputs": outputs})
    doc = {
        "description": "Reference outputs of the static film look (mixer, curves, saturation, print contrast, push/pull, characteristic curve) from tools/reference/film_look.py. Inputs and outputs are Display P3 encoded RGB triplets, flattened. No lens filter, halation, grain or reciprocity drift. An exact per-pixel port should match within 0.001; a port that bakes a 64^3 cube and samples it trilinearly within ~0.015 (steep slide-film curves when pushed).",
        "colorSpace": "Display P3 (sRGB transfer function)",
        "inputs": [round(v, 6) for p in pts for v in p],
        "cases": cases,
    }
    dst = ROOT / "profiles" / "test-vectors.json"
    dst.write_text(json.dumps(doc, separators=(",", ":")))
    print(f"{len(films)} films x {len(cases)} cases x {len(pts)} probes -> {dst}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "vectors":
        write_vectors()
    elif len(sys.argv) == 6 and sys.argv[1] == "show":
        film = next(f for f in load() if f["id"] == sys.argv[2])
        print(make_look(film)(*map(float, sys.argv[3:])))
    else:
        print(__doc__)

# GlassMeter Film Looks: Implementation Guide for AI Coding Agents

> **To the agent:** this file is self-contained. Read it end to end, then add the
> film simulations to the host iOS app. Everything you need is in this
> repository: data (`profiles/film-stocks.json`), a drop-in Swift package
> (`Sources/GlassFilmLooks`), a plain-Python reference
> (`tools/reference/film_look.py`), and test vectors
> (`profiles/test-vectors.json`).

**Repository:** https://github.com/TrondW/glassmeter-film-looks
**Source:** the film simulation engine from GlassMeter by Glass Works ([glass-works.ai](https://glass-works.ai))
**License:** [CC BY 4.0](LICENSE). Free to use, modify and ship, commercial use included. The only condition is credit.

---

## 0. The one requirement: credit

Add this line to the app's credits / acknowledgements / about screen (and the
App Store description's credits section, if there is one):

> **Film simulations from GlassMeter by Glass Works (glass-works.ai)**

The same string is available at runtime as `FilmProfileLibrary.bundled.attribution`.
If the app has no credits screen yet, create a simple one (Settings → About →
Acknowledgements is conventional).

**Film names.** Kodak, Portra, Ektar, Ektachrome, T-MAX, Tri-X, Fujifilm,
Velvia, Provia, Acros, Superia, Ilford, HP5, FP4, Delta, Pan F, XP2 and
CineStill are trademarks of their owners. These looks are original
interpretations, not affiliated with or endorsed by those companies. If the app
is published, consider labeling the picker "inspired by" or keeping a one-line
disclaimer near the credit.

---

## 1. Choose an integration path

| Host app renders with… | Do this |
|---|---|
| **Core Image** (CIImage / CIFilter / CIContext). Most iOS photo apps. | **Path A**: add the Swift package. About 20 lines of integration. |
| **Metal shaders, a custom GPU pipeline, or non-Apple code** | **Path B**: bake a 3D LUT with the package (or port the per-pixel function), then implement halation and grain from §4. |
| **Only needs static looks, no grain or halation** | Either path, or load the ready-made `.cube` files in `luts/cube-srgb-33/`. |

Path A is the most faithful and the least work. Prefer it whenever the app
already uses Core Image.

---

## 2. Path A: Swift package (Core Image)

### 2.1 Add the dependency

Xcode → File → Add Package Dependencies… → `https://github.com/TrondW/glassmeter-film-looks`
→ add the **GlassFilmLooks** library to the app target (not `glassfilm`, which is a
macOS command-line tool). Minimum iOS 15.

Or in a `Package.swift`:

```swift
.package(url: "https://github.com/TrondW/glassmeter-film-looks", branch: "main"),
// target dependency:
.product(name: "GlassFilmLooks", package: "glassmeter-film-looks"),
```

### 2.2 The API (that's all of it)

```swift
import GlassFilmLooks

let library = FilmProfileLibrary.bundled           // 31 profiles from film-stocks.json
let films = library.films                          // ordered for a picker
let portra = library.film(id: "kodak-portra-400")!

let renderer = FilmLookRenderer()                  // reuse it; NOT thread-safe
var options = FilmLookOptions()                    // grain + halation on by default
options.pushPullStops = 0                          // −3…+3, clamp to film.maxPullStops/maxPushStops
options.halationSpread = 0.2                       // lens "glow", 0.05…0.55
options.colorFilter = .none                        // .yellow/.orange/.red/.green for B&W, etc.

let output: CIImage = renderer.apply(portra, to: input, options: options)
```

`apply` works in **any** `CIContext` (default linear, Display P3, sRGB). It
converts to the encoding the looks were authored in and back out internally.
Do not pre-convert or pre-linearize the input.

Useful profile fields for UI: `displayName` ("Portra 400"), `manufacturer`,
`process` (`.colorNegative`, `.slide`, `.blackAndWhite`), `character` (a short
shop-clerk description, e.g. "Huge latitude, flawless skin tones"), `iso.box`,
`maxPushStops`, `maxPullStops`, `discontinued`. `digital-neutral` is a
pass-through ("no film") entry; `isNeutral` tells you which one it is.

### 2.3 Stills (editing / export)

```swift
let context = CIContext()                          // or the app's existing context
let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])!
let result = renderer.apply(film, to: image, options: options)
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let jpeg = context.jpegRepresentation(of: result, colorSpace: p3)
```

- **Apply at the final output resolution.** Grain size and halation radius
  scale with the image's short side (grain pattern = short side / 400, blur
  radius ∝ short side / 1000). Rendering a thumbnail and upscaling it changes
  the look; rendering full-size and downscaling is fine.
- Keep `grainOffset` fixed for stills, so re-renders are identical.

### 2.4 Live camera preview

- Keep **one** `FilmLookRenderer` per render queue. It caches a 64³ cube per
  (film, push) pair. Building one takes about 7 ms on an M-series Mac; expect
  tens of milliseconds on an iPhone the first time a film is selected.
  Pre-warm by calling `apply` once off-screen when the picker opens.
- Animate grain the way the app does: give `options.grainOffset` a random
  point in 0…256 every frame.
- Grain and halation are the expensive passes (a Gaussian blur and a noise
  overlay). If the preview drops frames, disable them in the preview and keep
  them for capture. GlassMeter does the same under thermal pressure.

### 2.5 Baking LUTs at runtime (optional)

```swift
// size³ RGB triplets, red fastest; encoded in `colorSpace`
let rgb = FilmLookLUT.sample(film, size: 33, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
let cubeText = FilmLookLUT.cubeFile(film)          // a .cube file as a String
```

---

## 3. Path B: Metal or any other pipeline

1. **Static look → 3D LUT.** Either:
   - call `FilmLookCube.data(for: film, pushPullStops:)`, which returns RGBA
     Float32 64³ cube data (red fastest, then green, then blue), ready for a
     3D texture; or
   - port the per-pixel function in §4.2 (Swift: `FilmLookCube.Look`;
     Python: `tools/reference/film_look.py`, about 150 lines, no dependencies).
2. **Encoding.** The look's input and output are **Display P3, encoded with the
   sRGB transfer function**, 0…1. If your pipeline is linear, encode before
   the lookup and decode after. If it is sRGB rather than P3, convert
   primaries (or accept the small gamut difference).
3. Clamp to 0…1 **before** the lookup, then sample with trilinear (or
   tetrahedral) interpolation.
4. Implement reciprocity drift, halation and grain from §4.3–§4.5, in the
   same encoded space, in that order, after the lookup.
5. Verify with §6.

---

## 4. The pipeline, precisely

All math runs on **Display P3 encoded values** (sRGB transfer curve), 0…1.
"Clamp" means clamp each channel to [0, 1]. Order matters.

```
input ─► lens filter ─► clamp ─► LOOK (one 3D LUT) ─► reciprocity drift ─► halation ─► grain ─► output
                                  │
                                  ├ 1 channel mixer (clamp)
                                  ├ 2 per-channel curves
                                  ├ 3 saturation
                                  ├ 4 print contrast (clamp)
                                  ├ 5 push/pull curve
                                  └ 6 characteristic curve (clamp)
```

### 4.1 Lens filter (optional, before the look)

A 3×3 RGB matrix, rows R, G, B (`out.r = m0·r + m1·g + m2·b`, …). These are
Wratten-derived and luminance-normalized:

| Filter | Matrix (row-major) |
|---|---|
| Yellow #8 | 1.05 0.05 0 · 0.05 1.0 0 · 0 0.05 0.13 |
| Orange #21 | 1.7 0.09 0 · 0.09 0.77 0 · 0 0 0.09 |
| Red #25 | 3.2 0.16 0 · 0 0.39 0 · 0 0 0.1 |
| Green #11 | 0.44 0.06 0 · 0.06 1.11 0.06 · 0 0.06 0.22 |
| Warming 81A | 1.05 0 0 · 0 1.0 0 · 0 0 0.84 |
| Conversion 85B | 1.32 0 0 · 0 0.95 0 · 0 0 0.59 |
| Conversion 80A | 0.76 0 0 · 0 1.03 0 · 0 0 1.38 |
| Polarizer | saturation × 1.15 (CIColorControls) |

Color filters exist mainly for black-and-white films; the red filter turns a
blue sky nearly black. Filters with exposure factors (ND, the color filters
themselves) would also need exposure compensation in a camera app. That's
outside the look.

### 4.2 The look (bake this into the LUT)

Per film, from `profiles/film-stocks.json → films[i].look`. Skip steps 1–4
and 6 for `digital-neutral` (its `characteristicCurve` is null).

1. **Channel mixer** (`channelMixer`, 9 numbers, row-major, may be null):
   `r' = m0 r + m1 g + m2 b`, `g' = m3 r + m4 g + m5 b`, `b' = m6 r + m7 g + m8 b`, then clamp.
   Black-and-white films use identical rows (e.g. 0.3 0.6 0.1), which is their
   panchromatic response.
2. **Curves** (`curves.red/green/blue`, `[x, y]` pairs on a 0–255 scale, may be null = identity):
   build a 256-entry table per channel. **Linear** interpolation between
   points, flat outside the first/last point, value `y / 255`. Look up with a
   **truncating** index: `table[min(max(Int(v × 255), 0), 255)]`.
3. **Saturation** (`saturation`, −1…+1): `L = 0.2126 r + 0.7152 g + 0.0722 b`,
   then each channel `c = L + (c − L) × (1 + saturation)`. No clamp here.
4. **Print contrast** (`contrast`): `k = 1 + 1.85 × contrast`,
   each channel `c = (c − 0.5) × k + 0.5`, then clamp.
5. **Push/pull** (`stops` = user choice, skip if 0): a monotone curve (below) through
   `(0,0) (0.25, clamp(0.25 − 0.03·s)) (0.5,0.5) (0.75, clamp(0.75 + 0.025·s)) (1,1)`.
6. **Characteristic curve** (`characteristicCurve`: `toeLift`, `shoulderCompression`, `midtoneSlope`):
   ```
   ceiling = 1 − shoulderCompression
   lower   = min(max(0.5 − 0.25·slope, toeLift + 0.02), 0.45)
   upper   = max(min(0.5 + 0.28·slope, ceiling − 0.02), 0.55)
   points  = (0, toeLift) (0.25, lower) (0.5, 0.5) (0.78, upper) (1, ceiling)
   ```
   Apply the monotone curve to each channel, then clamp.

**Monotone curve** (steps 5 and 6). Use a piecewise cubic Hermite with PCHIP
slopes, not a generic spline (and not `CIToneCurve`, whose spline and internal
transfer handling differ):

```
h_k = x_{k+1} − x_k            δ_k = (y_{k+1} − y_k) / h_k
m_0 = δ_0                      m_n = δ_{n−1}                    (one-sided ends)
interior: m_k = 0 if δ_{k−1}·δ_k ≤ 0, else
          w1 = 2h_k + h_{k−1},  w2 = h_k + 2h_{k−1}
          m_k = (w1 + w2) / (w1/δ_{k−1} + w2/δ_k)
eval x (clamped to [x_0, x_n]) in segment k, t = (x − x_k)/h_k:
   y = (2t³−3t²+1)·y_k + (t³−2t²+t)·h_k·m_k + (−2t³+3t²)·y_{k+1} + (t³−t²)·h_k·m_{k+1}
```

GlassMeter's cube is 64³. 33³ is enough for exported `.cube` files.

### 4.3 Reciprocity drift (optional, color films only)

For long exposures in a camera app. With metered time `t` seconds and the film's
`reciprocity` (`thresholdSeconds` T, `exponent` p):
`t_c = T·(t/T)^p` if `t ≥ T`, else `t`. If `t_c > 1.05·t`:
`w = min(1, log2(t_c / t))`, then `r ×= 1 + 0.05w`, `g ×= 1 + 0.01w`, `b ×= 1 − 0.06w`.
The same formula tells a shooter how much longer to expose.

### 4.4 Halation (red highlight bloom)

On when the user enables it **or** `halation.alwaysOn` (CineStill). Strength
`I = halationSpread × halation.factor` (factor: CineStill 1.3, B&W 0.3,
others 1.0). Skip if `I ≤ 0.01`.

1. Highlights per channel: `t = clamp(4c − 2.8)` (rises over 0.70 → 0.95),
   `h = 0.15·(3t² − 2t³)`.
2. Gaussian blur `h` with radius `30·I·(shortSide / 1000)` px (Core Image radius).
3. Tint, color films only: `R' = R`, `G' = 0.1R + 0.2G`, `B' = 0.05B`. B&W stays neutral.
4. Scale by 0.3, then **screen** over the image: `out = 1 − (1 − img)(1 − bloom)`.

### 4.5 Grain

`g = grain.intensity × max(0.1, 1.3^pushPullStops)`. Skip if `g ≤ 0.01`.
Four films (Portra 400, Gold 200, Pro 400H, Industrial 100) have intensity 0
and get no grain at box speed.

1. Uniform noise per pixel in 0…1, monochrome. With Core Image:
   `CIRandomGenerator` → `CIColorMonochrome` (color 0.5 gray, intensity 1).
2. Contrast around 0.5: `n' = (n − 0.5)·(0.3g) + 0.5`.
3. Upscale the noise pattern by `shortSide / 400` (chunky grain clumps), cropped to the image.
4. **Overlay** blend the noise onto the image (noise = top layer).
5. Luminance weighting: `L` = Rec.709 luma of the *pre-grain* image,
   `mask = 0.25 + 3L − 3L²` (peaks at mid-gray), `out = mix(img, grained, mask)`.

---

## 5. Data reference: `profiles/film-stocks.json`

```jsonc
{
  "schema": "glassmeter-film-looks/1",
  "attribution": "Film simulations from GlassMeter by Glass Works (glass-works.ai)",
  "films": [{
    "id": "kodak-portra-400",              // stable; use for persistence
    "name": "Kodak Portra 400",  "displayName": "Portra 400",  "manufacturer": "Kodak",
    "process": "C-41",                      // "C-41" color negative | "E-6" slide | "BW"
    "iso": { "box": 400, "min": 200, "max": 1600 },
    "maxPushStops": 2, "maxPullStops": 1,   // realistic push/pull range
    "discontinued": false,
    "character": "Huge latitude, flawless skin tones",
    "notes": null,
    "look": {
      "channelMixer": [9 numbers] | null,
      "curves": { "red": [[x,y],…], "green": …, "blue": … } | null,   // 0–255
      "saturation": -0.10,
      "contrast": 0.10,
      "characteristicCurve": { "toeLift": 0.04, "shoulderCompression": 0.10, "midtoneSlope": 0.90 } | null
    },
    "grain":       { "intensity": 0.0 },
    "halation":    { "factor": 1.0, "alwaysOn": false },
    "reciprocity": { "thresholdSeconds": 1.0, "exponent": 1.3 }
  }]
}
```

31 entries: 30 films (Kodak, Fujifilm, Ilford, CineStill; color negative,
slide and B&W) plus `digital-neutral`.

---

## 6. Verify the integration

- **Swift package:** `swift test` in this repo checks the package against the
  test vectors in both a Display P3 and a default Core Image context.
- **Your own port:** `profiles/test-vectors.json` has 189 input colors
  (Display P3 encoded) and the expected look output for every film at push 0,
  +2 and −1 (no lens filter, halation, grain or drift). Targets: an exact
  per-pixel port within **0.001**; a 64³ cube sampled trilinearly within
  **~0.015**.
- **Eyeball check:** render a photo with every film and compare against
  `samples/contact-sheet.jpg` (rendered with grain and halation on,
  `halationSpread` 0.2).

### Pitfalls this guide has already paid for

- **Linear vs encoded.** The looks were authored on display-encoded values.
  Applying the cube to linear data (the default CIContext working space) without
  conversion gives crushed, wrong-hued results. The package handles this; a
  custom port must too.
- **Clamp before every cube lookup.** Out-of-range values (exposure boosts,
  strong filters) come back from a 3D LUT as psychedelic hues.
- **Contrast is not in the 256-entry curve tables.** Apply steps 1–6 in order.
- **Don't substitute `CIToneCurve`** for the monotone curves.
- **Grain and halation are resolution-relative.** Render them at output size.

---

## 7. Other deliverables in this repo (for people, not the app)

- `luts/cube-srgb-33/*.cube`: 33³ LUTs, sRGB in/out, for Photoshop (Color
  Lookup adjustment), Capture One, DaVinci Resolve, Final Cut Pro, Affinity
  Photo, and similar tools.
- `lightroom/profiles/*.xmp`: Lightroom / Camera Raw creative profiles (group
  "GlassMeter Film"). See the README for install steps.
- Regenerate everything with `swift run -c release glassfilm cubes|lightroom|render …`
  (macOS).

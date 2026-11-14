# How calc_bg_color works, from zero

This guide assumes you know nothing about images or color math. Read it top to
bottom once, then open the matching source file next to each section. Every
source file starts with a comment block that repeats the idea in short.

**Reading order of the code**

| # | File | What it does |
|---|---|---|
| 1 | `lib/src/image/rgba_image.dart` | How a picture is stored as numbers |
| 2 | `lib/src/color/color_math.dart` | All color formulas |
| 3 | `lib/src/steps/border_detector.dart` | Step 1: is the logo inside a solid box? |
| 4 | `lib/src/steps/background_remover.dart` | Step 2: make the box transparent |
| 5 | `lib/src/steps/trimmer.dart` | Step 3: cut empty margins |
| 6 | `lib/src/steps/palette_extractor.dart` | Step 4: which colors is the logo made of? |
| 7 | `lib/src/steps/contrast_checker.dart` | Step 5: does it blend into my background? |
| 8 | `lib/src/steps/background_recommender.dart` | Step 6: what background should I use? |
| 9 | `lib/src/pipeline/logo_pipeline.dart` | Runs steps 1–6 in order |
| 10 | `lib/src/flutter/logo_analyzer.dart` | Loads a Flutter image, makes PNG, caches |
| 11 | `lib/src/widgets/logo_halo.dart` | Outline that follows the logo's shape |
| 12 | `lib/src/widgets/adaptive_logo.dart` | The one-line widget |
| — | `test/` | Every step tested with tiny fake images |

Folders 1–9 are **pure Dart**: they never touch widgets, the network or the GPU.
That's why they're easy to test, and why you can change one step without
breaking the others.

---

## 1. A picture is just a list of numbers

A screen pixel mixes **R**ed, **G**reen and **B**lue light. Each one is a
number from **0** (off) to **255** (full). A 4th number, **A**lpha, is opacity:
0 = invisible, 255 = solid.

| Pixel | R | G | B | A | Looks like |
|---|---|---|---|---|---|
| white | 255 | 255 | 255 | 255 | white |
| black | 0 | 0 | 0 | 255 | black |
| brand blue `#1E40AF` | 30 | 64 | 175 | 255 | dark blue |
| invisible | anything | | | 0 | nothing |

`#1E40AF` is the same three numbers written in hexadecimal: `1E` = 30,
`40` = 64, `AF` = 175.

An image of 400 × 200 pixels is stored as one long list of
400 × 200 × 4 = 320,000 bytes: `R G B A R G B A ...`, row after row. To find
pixel (x, y):

```
index = (y * width + x) * 4      // index of R; G is +1, B is +2, A is +3
```

`y * width` skips the full rows above, `+ x` moves along the row, and `* 4`
because every pixel takes 4 bytes. That's exactly `RgbaImage.indexOf`.

### Straight vs premultiplied alpha
A half-transparent red can be stored two ways:
- **straight**: `255, 0, 0, 128`, meaning the color is red and it's 50% visible.
- **premultiplied**: `128, 0, 0, 128`, where the color was already multiplied by the alpha.

We always ask Flutter for **straight** (`ImageByteFormat.rawStraightRgba`).
With premultiplied bytes, every soft edge pixel would look darker than it
really is, and our color checks would be wrong. *(Your original `main.dart`
used `rawRgba`, which is premultiplied.)*

---

## 2. The color math (`color_math.dart`)

### 2.1 Screens don't store light linearly
You might think byte 128 is "half as bright" as 255. It isn't: it's only
about **22%** as bright. Screens use a curve called **sRGB gamma**, because our
eyes notice changes in dark colors more than in bright ones.

Before doing any math with *light* we undo the curve:

```
c = byte / 255
linear = c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ^ 2.4
```

Example: byte 128 → c = 0.502 → ((0.502 + 0.055)/1.055)^2.4 = **0.216**.

Images have hundreds of thousands of pixels but a byte only has 256 possible
values, so `ColorMath.linearLut` computes all 256 answers once and looks them
up afterwards. That's why pixel loops stay fast.

### 2.2 Luminance: how bright a color *looks*
Our eyes are very sensitive to green, less to red, and much less to blue:

```
L = 0.2126 * R_linear + 0.7152 * G_linear + 0.0722 * B_linear
```

Worked example, brand blue `#1E40AF` (30, 64, 175):

| | byte | c = byte/255 | linear |
|---|---|---|---|
| R | 30 | 0.118 | 0.0129 |
| G | 64 | 0.251 | 0.0513 |
| B | 175 | 0.686 | 0.4287 |

L = 0.2126·0.0129 + 0.7152·0.0513 + 0.0722·0.4287 = 0.0027 + 0.0367 + 0.0310
= **0.070**. Blue is very dark to the eye, even though its B byte is high.

### 2.3 Contrast ratio (WCAG)

```
contrast = (L_lighter + 0.05) / (L_darker + 0.05)
```

The 0.05 represents screen glare: even "black" reflects a bit of light.

- white (1.0) vs black (0.0): 1.05 / 0.05 = **21**, the maximum
- white vs brand blue: 1.05 / (0.070 + 0.05) = **8.7**
- a color vs itself: **1**, the minimum

Rules of thumb (WCAG): 3:1 for icons and large text, 4.5:1 for body text.

**Weakness:** contrast only compares *brightness*. Red `#DC2626` and green
`#16A34A` have similar brightness, so their contrast is low (~1.5) even though
nobody would confuse them. That's why we also use OKLab.

### 2.4 OKLab: distance = how different it looks
In RGB, the "distance" between two colors doesn't match what we see: two
greens 40 bytes apart can look identical while two blues 40 bytes apart look
very different. **OKLab** (Björn Ottosson, 2020) is a color space built so
that the straight-line distance matches human perception.

It has 3 numbers:
- **L**: lightness, 0 = black and 1 = white
- **a**: green (−) to red (+)
- **b**: blue (−) to yellow (+)

Conversion, as done in `_linearToOkLab`:
1. linear RGB → **LMS**, how strongly each of the 3 cone types in your eye reacts (3 fixed weighted sums);
2. take the **cube root** of each, because eyes respond roughly like a cube root;
3. 3 more weighted sums → L, a, b.

The difference between two colors is then plain Pythagoras:

```
difference = sqrt( (L1-L2)² + (a1-a2)² + (b1-b2)² )
```

| difference | meaning |
|---|---|
| 0 | identical |
| < 0.02 | most people can't tell them apart |
| ~0.1 | look similar |
| > 0.3 | clearly different |
| 1.0 | black vs white |

**Which one is used where?**
- *Is this pixel the same as the box color?* → OKLab difference (steps 1, 2, 4)
- *Can you see the logo on this background?* → both contrast **and** OKLab difference (step 5)

### 2.5 Brand tints
`ColorMath.withLightness(color, 0.96, chromaScale: 0.3)` keeps the **hue** of
the logo's color (the angle `atan2(b, a)` in OKLab) but sets its lightness to
0.96 and keeps only 30% of its colorfulness. A blue logo gets a very pale blue
backdrop: it matches the brand but still has contrast. Step 6 tries a light
(0.96) and a dark (0.25) tint.

---

## 3. The pipeline, step by step

```
image ──► 1 border ──► 2 remove box ──► 3 trim ──► 4 palette   (once per logo)
                                                       │
                          background ──► 5 contrast ◄──┘
                                         6 recommend           (per background)
```

### Step 1: Border detector
A JPG logo usually sits on a white rectangle. If so, almost every pixel on the
**outer edge** has the same color.

1. Collect the pixels in a ring `ringWidth` (2) pixels deep around the image.
2. If ≥ 50% of them are transparent, it's already a cut-out PNG. Stop.
3. Put the opaque ones in color buckets (explained in step 4) and take the
   fullest bucket's average color, for example white.
4. **Uniformity** = share of edge pixels within OKLab 0.06 of that color.
   If ≥ 80%, it's a box.

### Step 2: Background remover
For each pixel, `d` = OKLab difference from the box color:

```
d ≤ tolerance (0.08)               → alpha = 0          (background)
d between 0.08 and 0.08+feather    → alpha scaled 0..1  (soft edge)
d ≥ 0.14                           → unchanged          (logo)
```

**Why feather?** Anti-aliased edges are a mix of logo and box. Cutting them
hard leaves a jagged, light fringe.

**Flood fill vs global.** Picture a blue ring with a white hole inside,
on a white box:

```
global:      every white pixel removed → the hole disappears ✗
flood fill:  start from the edges and spread only into touching
             background pixels → stops at the blue ring,
             so the white hole survives ✓
```

The flood fill is a "stack" loop: put all edge pixels on a stack; pop one; if
it's background, make it transparent and push its 4 neighbours; if it's logo,
stop there. `visited` makes sure each pixel is only handled once.
*(Your original code used the global approach.)*

### Step 3: Trimmer
Find the smallest rectangle containing every pixel with alpha ≥ 16, add
optional padding, and copy that rectangle row by row. Now a fixed `width: 160`
means "the artwork is 160 px wide", not "the artwork plus a random margin".

### Step 4: Palette extractor ("bucket and merge")
**Why not average all pixels?** 70% blue + 30% white averages to a pale blue
that's nowhere in the logo. *(Your original code averaged all pixels.)*

1. **Buckets.** `r >> 4` keeps the top 4 bits: 0..255 becomes 0..15. With 16
   levels per channel there are 16 × 16 × 16 = **4096 buckets**. Each bucket
   counts pixels and sums their exact r, g, b.
   Example: (30, 64, 175) → (1, 4, 10) → bucket 1·256 + 4·16 + 10 = **330**.
2. **Sort** buckets from most pixels to fewest.
3. **Merge.** Biggest bucket first: if it's within OKLab `mergeDistance`
   (0.08) of an existing color, add it to that color (sums keep the average
   exact); otherwise start a new color. After `maxColors` (6), the rest join
   the nearest.

Result: `[blue 75%, white 25%]`. Pixels with alpha < 128 (soft edges) are
skipped so they don't create fake in-between colors.

### Step 5: Contrast checker
Each logo color **blends in** if it fails *either* test:
- contrast < `minContrast` (2.0), meaning similar brightness;
- OKLab difference < `minDifference` (0.12), meaning a similar-looking color.

`blendShare` = the sum of the shares of the blending colors. **Conflict** if
`blendShare > maxBlendShare` (12%).

Example: logo = blue 75% + white 25%:

| background | blue | white | blendShare | conflict? |
|---|---|---|---|---|
| white | 8.7:1 ✓ | 1:1 ✗ | 25% | **yes**, the white part vanishes |
| black | 2.4:1 ✓ | 21:1 ✓ | 0% | no |
| blue | 1:1 ✗ | 8.7:1 ✓ | 75% | **yes** |

Why 2.0 and not WCAG's 3.0? Colorful logos such as orange on white (~2.8) look fine to
people. Set `minContrast: 3.0` for strict accessibility.

### Step 6: Background recommender
Other packages pick a background color *from* the logo, which can hide it. We
try **candidates** and score how well the logo shows on each:

- your current background,
- your own colors (`RecommendationOptions.candidates`),
- neutrals: white, light gray, dark slate, black,
- brand tints: a light and a dark version of the logo's main color.

```
score = 0.60 × visibleShare        (1 − blendShare)
      + 0.25 × contrastScore       ((min(worstContrast, 7) − 1) / 6)
      + 0.15 × closeness           (1 − difference from current background)
```

- `visibleShare` matters most: the logo must show.
- `contrastScore` rewards strong edges, capped at 7:1 because more doesn't look better.
- `closeness` prefers *small* changes to your design.

Example, white logo on a white header:
- white: visible 0, contrast score 0, closeness 1 → **0.15**
- dark slate: visible 1, contrast 17.8 capped at 7 → 1, closeness ≈ 0.21 → **0.88** ← wins
- black: visible 1, contrast 21 → 1, closeness 0 → **0.85**

`recommendedBackground` stays your current one when there's no conflict. The
weights are options, so you can tune them.

### Halo color
To outline a logo you need a color that stands out from the **background**
(not from the logo). We pick black or white, whichever has the higher contrast
with the background.

---

## 4. The Flutter layer

### LogoAnalyzer.prepare
1. `ResizeImage(..., policy: fit, allowUpscaling: false)` makes the engine
   decode the image directly at ≤ 400 px. That's faster and uses less memory
   than decoding full size and shrinking afterwards *(your original code did the latter)*.
2. `toByteData(rawStraightRgba)` gives the bytes as an `RgbaImage`.
3. `LogoPipeline.run`: steps 1–4.
4. `decodeImageFromPixels` + `toByteData(png)` turns the cleaned pixels into
   PNG bytes for `Image.memory`.
5. The result is cached (64 logos by default) and identical requests running
   at the same time share one job.

### LogoHalo
1. `ColorFilter.mode(color, BlendMode.srcIn)` keeps the logo's *shape* but paints it in one color: a silhouette.
2. Draw it 8 times, shifted `spread` px in 8 directions, to get a silhouette slightly bigger than the logo.
3. Blur it.
4. Draw the real logo on top.

### AdaptiveLogo
- In `initState` (or when the **image** changes), it runs `prepare`, the slow part.
- In every `build`, it runs `evaluate(background)`. That's instant (about 6 colors × about 8 candidates), so switching themes needs no reprocessing.
- While loading, or on error (CORS), it shows the original image.
- `onEvaluated` is called after the frame and only when something changed, so a `setState` in the callback can't loop forever.

---

## 5. Where to customize

| I want to... | Change |
|---|---|
| keep white shapes inside logos | `RemovalOptions(floodFill: true)` (default) |
| remove more of a noisy background | raise `RemovalOptions.tolerance` |
| smoother or harder edges | `RemovalOptions.feather` |
| fewer, broader logo colors | raise `PaletteOptions.mergeDistance` |
| strict accessibility | `ContrastOptions(minContrast: 3.0)` |
| only use my theme colors | `RecommendationOptions(candidates: [...], includeNeutrals: false, includeBrandTints: false)` |
| never change my background much | raise `closenessWeight` |
| faster processing | lower `LogoOptions.maxDimension` |

## 6. Ideas for later
- Run steps 1–4 in an isolate (`compute`) on mobile/desktop for large images.
- "Decontaminate" feathered edge pixels (remove the box's tint from their color).
- APCA contrast as an alternative to WCAG 2.
- Text-on-logo detection for very thin strokes.

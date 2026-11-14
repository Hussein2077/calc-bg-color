# calc_bg_color

Make user-uploaded logos look right on **your** background.

Logos uploaded by users arrive as JPGs inside white boxes, with random
margins, in colors that may vanish on your header. `calc_bg_color` fixes that
entirely on the device, with **no dependencies** besides Flutter:

1. **Detects** a solid background box around the logo.
2. **Removes** it with soft edges, using a flood fill that keeps white shapes *inside* the logo.
3. **Trims** empty margins, so a fixed width means the same size for every logo.
4. **Finds the real colors** of the logo and how much of it each one covers.
5. **Checks** whether the logo blends into your app background (WCAG contrast plus OKLab perceptual difference).
6. **Recommends** a better background (your theme colors, neutrals or brand tints) when it does.
7. **Draws a halo** that follows the logo's shape when you keep your background.

Works on Android, iOS, web, Windows, macOS and Linux.

## How it differs from other packages

| | calc_bg_color | palette / dominant-color packages |
|---|---|---|
| Background color | chosen to keep the **logo visible** | taken **from** the logo (can hide it) |
| Checks against *your* app background | ✅ | ❌ |
| Removes JPG background boxes | ✅ flood fill + feathering | ❌ |
| Trims margins | ✅ | ❌ |
| Shape-following halo | ✅ | ❌ |
| Color distance | OKLab (perceptual) | RGB |
| Dependencies | none | some |

## Install

```yaml
dependencies:
  calc_bg_color: ^0.1.0
```

## Use it

### One widget

```dart
import 'package:calc_bg_color/calc_bg_color.dart';

AdaptiveLogo(
  image: NetworkImage(company.logoUrl),
  background: Theme.of(context).colorScheme.surface,
  width: 160,
  effect: AdaptiveLogoEffect.halo, // or backdrop, alwaysBackdrop, none
)
```

### Without widgets

```dart
final logo = await LogoAnalyzer.prepare(NetworkImage(url));

final result = logo.evaluate(const Color(0xFF1E40AF));
result.hasConflict;            // true if the logo blends in
result.contrast.reason;        // "30% of the logo blends into #1E40AF ..."
result.recommendedBackground;  // the color to use instead
result.suggestions;            // all candidates, best first
result.haloColor;              // outline color if you keep your background

Image.memory(logo.pngBytes);   // the cleaned, trimmed logo
```

`prepare` does the pixel work once (cached). `evaluate` is instant, so you can
call it again whenever the theme changes.

### Pure Dart, step by step
Every step works on its own with raw pixels, which is handy for tests or servers:

```dart
final report = LogoPipeline.run(RgbaImage(width, height, rgbaBytes));
final palette = PaletteExtractor.extract(report.cleaned);
final check = ContrastChecker.check(palette, Colors.white);
```

## Customize

```dart
AdaptiveLogo(
  image: image,
  background: bg,
  options: const LogoOptions(
    maxDimension: 300,
    removal: RemovalOptions(tolerance: 0.1, feather: 0.04, floodFill: true),
    trim: TrimOptions(padding: 4),
    palette: PaletteOptions(maxColors: 4),
  ),
  contrast: const ContrastOptions(minContrast: 3.0), // strict WCAG
  recommendation: RecommendationOptions(
    candidates: [myTheme.surface, myTheme.primaryContainer],
    includeBrandTints: true,
  ),
  haloStyle: const LogoHaloStyle(spread: 2, blur: 2),
)
```

All options are documented in the code. See
[doc/how_it_works.md](doc/how_it_works.md) for a beginner-friendly explanation
of every formula with worked numbers.

## Web note (CORS)
On Flutter Web, reading the pixels of an image from another server requires
that server to send `Access-Control-Allow-Origin`. If it doesn't, `prepare`
throws and `AdaptiveLogo` falls back to showing the original image.

## Example

```bash
cd example
flutter run -d chrome
```

## License
MIT. See [LICENSE](LICENSE).

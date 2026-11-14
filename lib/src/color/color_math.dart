// =============================================================================
// color_math.dart
//
// All the color formulas the package needs, in one place:
//
//   1. sRGB  <-> linear light        (how screens encode brightness)
//   2. relative luminance            (how bright a color LOOKS to a human)
//   3. contrast ratio                (the WCAG "is it readable?" number)
//   4. OKLab                         (a color space where distance = how
//                                     different two colors LOOK)
//
// Nothing here knows about images or widgets. It only uses `Color` from
// dart:ui, so every function can be unit-tested on its own.
//
// Read doc/how_it_works.md, section 2, for the same ideas explained with
// worked numbers.
// =============================================================================

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

/// A color in the OKLab color space.
///
/// * [l] is lightness: 0 = black, 1 = white.
/// * [a] is the green (negative) to red (positive) axis.
/// * [b] is the blue (negative) to yellow (positive) axis.
///
/// The straight-line distance between two [OkLab] colors matches how
/// different they look to a person much better than distance in RGB.
class OkLab {
  /// Creates an OKLab color from its three components.
  const OkLab(this.l, this.a, this.b);

  /// Lightness, 0 (black) to 1 (white).
  final double l;

  /// Green (-) to red (+).
  final double a;

  /// Blue (-) to yellow (+).
  final double b;

  /// Chroma: how colorful the color is (0 = a gray).
  double get chroma => math.sqrt(a * a + b * b);

  /// Hue angle in radians (only meaningful when [chroma] is not ~0).
  double get hue => math.atan2(b, a);

  /// Distance to [other]. 0 = identical, 1 = black vs white.
  double distanceTo(OkLab other) {
    final dl = l - other.l;
    final da = a - other.a;
    final db = b - other.b;
    return math.sqrt(dl * dl + da * da + db * db);
  }

  @override
  String toString() =>
      'OkLab(l: ${l.toStringAsFixed(3)}, a: ${a.toStringAsFixed(3)}, '
      'b: ${b.toStringAsFixed(3)})';
}

/// Static color helpers. `ColorMath.contrastRatio(a, b)` and so on.
abstract final class ColorMath {
  // ---------------------------------------------------------------------------
  // 1. sRGB <-> linear
  // ---------------------------------------------------------------------------

  /// Converts one sRGB channel (0..1) to linear light (0..1).
  ///
  /// Screens store brightness "gamma encoded": the byte value 128 is NOT half
  /// as bright as 255, it is only about 22% as bright. To do math with light
  /// (averaging, luminance) we must first undo that encoding.
  static double srgbToLinear(double channel) {
    // Very dark values use a straight line, the rest a power curve.
    // These exact numbers come from the sRGB standard (IEC 61966-2-1).
    return channel <= 0.04045
        ? channel / 12.92
        : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
  }

  /// The reverse of [srgbToLinear].
  static double linearToSrgb(double linear) {
    final v = linear <= 0.0031308
        ? linear * 12.92
        : 1.055 * math.pow(linear, 1 / 2.4) - 0.055;
    return v.clamp(0.0, 1.0);
  }

  /// [srgbToLinear] pre-computed for every byte value 0..255.
  ///
  /// Images have hundreds of thousands of pixels. Calling `pow` for each one
  /// is slow, but a pixel byte can only be one of 256 values, so we compute
  /// all 256 answers once and then just look them up.
  static final Float64List linearLut = Float64List.fromList([
    for (var i = 0; i < 256; i++) srgbToLinear(i / 255),
  ]);

  // ---------------------------------------------------------------------------
  // 2. Relative luminance
  // ---------------------------------------------------------------------------

  /// How bright [color] looks, from 0 (black) to 1 (white).
  ///
  /// Human eyes are most sensitive to green, then red, and much less to blue.
  /// That is why the weights are 0.7152 for green but only 0.0722 for blue:
  /// pure blue looks very dark, pure green looks bright.
  ///
  /// Same result as Flutter's `Color.computeLuminance()`; written out here so
  /// you can see the formula.
  static double luminance(Color color) {
    final r = srgbToLinear(color.r);
    final g = srgbToLinear(color.g);
    final b = srgbToLinear(color.b);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  // ---------------------------------------------------------------------------
  // 3. Contrast ratio (WCAG 2.x)
  // ---------------------------------------------------------------------------

  /// Contrast ratio between two colors, from 1 (same) to 21 (black/white).
  ///
  /// Formula: (lighter + 0.05) / (darker + 0.05).
  /// The 0.05 stands for screen glare: even "black" reflects a little light.
  ///
  /// WCAG guidelines: 3:1 for icons/large text, 4.5:1 for normal text.
  static double contrastRatio(Color a, Color b) {
    final la = luminance(a);
    final lb = luminance(b);
    final lighter = math.max(la, lb);
    final darker = math.min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Black or white: whichever is more readable on [background].
  static Color readableOn(
    Color background, {
    Color light = const Color(0xFFFFFFFF),
    Color dark = const Color(0xFF000000),
  }) {
    return contrastRatio(light, background) >= contrastRatio(dark, background)
        ? light
        : dark;
  }

  // ---------------------------------------------------------------------------
  // 4. OKLab (https://bottosson.github.io/posts/oklab/)
  // ---------------------------------------------------------------------------

  /// Converts a Flutter [Color] to [OkLab].
  static OkLab toOkLab(Color color) => _linearToOkLab(
    srgbToLinear(color.r),
    srgbToLinear(color.g),
    srgbToLinear(color.b),
  );

  /// Converts 8-bit channels (0..255, straight from image bytes) to [OkLab].
  /// Uses [linearLut], so it is fast enough to call for every pixel.
  static OkLab rgb8ToOkLab(int r, int g, int b) =>
      _linearToOkLab(linearLut[r], linearLut[g], linearLut[b]);

  static OkLab _linearToOkLab(double r, double g, double b) {
    // Step 1: linear RGB -> "LMS", the response of the three cone types
    // (long, medium, short wavelength) in the human eye.
    final l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
    final m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
    final s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;

    // Step 2: cube root. Our eyes respond to light roughly like a cube root:
    // doubling the light does not look twice as bright.
    final l_ = _cbrt(l);
    final m_ = _cbrt(m);
    final s_ = _cbrt(s);

    // Step 3: mix the cone responses into lightness + two color axes.
    return OkLab(
      0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
      1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
      0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
    );
  }

  /// Converts [OkLab] back to a Flutter [Color] (the steps above, reversed).
  ///
  /// Some OKLab values have no exact screen color ("out of gamut"); those
  /// channels are clamped to 0..1.
  static Color fromOkLab(OkLab lab, {double opacity = 1}) {
    final l_ = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b;
    final m_ = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b;
    final s_ = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b;

    final l = l_ * l_ * l_;
    final m = m_ * m_ * m_;
    final s = s_ * s_ * s_;

    final r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    final g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    final b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;

    return Color.from(
      alpha: opacity,
      red: linearToSrgb(r),
      green: linearToSrgb(g),
      blue: linearToSrgb(b),
    );
  }

  /// How different two colors look: 0 = identical, 1 = black vs white.
  ///
  /// Rough guide: below 0.02 most people can't tell them apart, around 0.1
  /// they look "similar", above 0.3 clearly different.
  static double difference(Color a, Color b) =>
      toOkLab(a).distanceTo(toOkLab(b));

  /// Builds a color with the same hue as [color] but a chosen [lightness]
  /// (0..1) and with its chroma (colorfulness) multiplied by [chromaScale].
  ///
  /// Used to make "brand tints": a very light or very dark version of the
  /// logo's own color.
  static Color withLightness(
    Color color,
    double lightness, {
    double chromaScale = 1,
  }) {
    final lab = toOkLab(color);
    final c = lab.chroma * chromaScale;
    final h = lab.hue;
    return fromOkLab(OkLab(lightness, c * math.cos(h), c * math.sin(h)));
  }

  /// Formats [color] as `#RRGGBB` (handy for logs and UI labels).
  static String toHex(Color color) {
    final rgb = color.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  // Dart's math library has no cube root, so we build one from pow.
  // pow() does not accept negative bases with fractional exponents,
  // so we handle the sign ourselves.
  static double _cbrt(double x) =>
      x < 0 ? -math.pow(-x, 1 / 3).toDouble() : math.pow(x, 1 / 3).toDouble();
}

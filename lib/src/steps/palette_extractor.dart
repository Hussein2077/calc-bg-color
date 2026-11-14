// =============================================================================
// palette_extractor.dart  (pipeline step 4)
//
// Question it answers: "Which colors is this logo made of, and how much of
// each?"
//
// Why not just average all pixels? A logo that is 70% blue and 30% white
// averages to a pale blue that appears NOWHERE in the logo. We would then
// check contrast against a color that does not exist. So instead we find
// the few real colors and their share.
//
// The algorithm ("bucket and merge") in plain words:
//
//   1. BUCKETS. Put every visible pixel into a bucket by its rough color.
//      We keep only the top 4 bits of each channel (r >> 4), so 0..255
//      becomes 0..15, and there are 16 x 16 x 16 = 4096 buckets.
//      Each bucket remembers how many pixels fell in and the SUM of their
//      exact r, g, b, so we can compute an exact average later.
//
//   2. SORT the buckets from most pixels to fewest.
//
//   3. MERGE. Walk the buckets, biggest first. If a bucket's color looks
//      almost the same (OKLab distance <= mergeDistance) as a color we
//      already kept, add it to that color. Otherwise keep it as a new color.
//      Once we have maxColors colors, the rest join the closest one.
//
// The result is a short list like:  blue 68%, white 29%, gray 3%.
// =============================================================================

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../color/color_math.dart';
import '../image/rgba_image.dart';

/// Settings for [PaletteExtractor].
@immutable
class PaletteOptions {
  /// Creates palette settings. All values have sensible defaults.
  const PaletteOptions({
    this.maxColors = 6,
    this.mergeDistance = 0.08,
    this.alphaThreshold = 128,
  }) : assert(maxColors >= 1, 'maxColors must be at least 1'),
       assert(mergeDistance >= 0, 'mergeDistance must be >= 0');

  /// The most colors to return.
  final int maxColors;

  /// Colors closer than this (OKLab distance) are treated as one color.
  /// Bigger = fewer, broader colors. 0.08 means "looks like the same color".
  final double mergeDistance;

  /// Pixels with alpha below this are ignored. 128 skips the soft,
  /// half-transparent edge pixels that are a mix of logo and background.
  final int alphaThreshold;

  @override
  bool operator ==(Object other) =>
      other is PaletteOptions &&
      other.maxColors == maxColors &&
      other.mergeDistance == mergeDistance &&
      other.alphaThreshold == alphaThreshold;

  @override
  int get hashCode => Object.hash(maxColors, mergeDistance, alphaThreshold);
}

/// One color of a logo and how much of the logo it covers.
@immutable
class LogoSwatch {
  /// Creates a swatch.
  const LogoSwatch({
    required this.color,
    required this.pixelCount,
    required this.share,
  });

  /// The average color of all pixels in this group (always fully opaque).
  final Color color;

  /// How many pixels belong to this color.
  final int pixelCount;

  /// Fraction of the visible logo, 0..1. All shares add up to 1.
  final double share;

  @override
  String toString() =>
      'LogoSwatch(${ColorMath.toHex(color)}, '
      '${(share * 100).toStringAsFixed(1)}%)';
}

/// The colors of a logo, biggest first.
@immutable
class LogoPalette {
  /// Creates a palette from [swatches] (expected biggest first).
  const LogoPalette(this.swatches, {required this.visiblePixels});

  /// A palette with no colors (fully transparent image).
  static const LogoPalette empty = LogoPalette([], visiblePixels: 0);

  /// The colors, sorted by [LogoSwatch.share], biggest first.
  final List<LogoSwatch> swatches;

  /// How many pixels were counted (alpha >= the threshold).
  final int visiblePixels;

  /// True when the image had no visible pixels.
  bool get isEmpty => swatches.isEmpty;

  /// The color covering the most of the logo, or null if [isEmpty].
  LogoSwatch? get dominant => swatches.isEmpty ? null : swatches.first;

  @override
  String toString() => 'LogoPalette($swatches)';
}

/// Finds the main colors of an image. See the comment at the top of the file.
abstract final class PaletteExtractor {
  // 4 bits per channel -> 16 levels -> 16*16*16 = 4096 buckets.
  static const int _bits = 4;
  static const int _levels = 1 << _bits; // 16
  static const int _bucketCount = _levels * _levels * _levels; // 4096

  /// Extracts the palette of [image].
  static LogoPalette extract(
    RgbaImage image, {
    PaletteOptions options = const PaletteOptions(),
  }) {
    final px = image.pixels;

    // ---- Step 1: fill the buckets -----------------------------------------
    final counts = Int32List(_bucketCount);
    final sumR = Float64List(_bucketCount);
    final sumG = Float64List(_bucketCount);
    final sumB = Float64List(_bucketCount);
    var visible = 0;

    for (var i = 0; i < px.length; i += 4) {
      if (px[i + 3] < options.alphaThreshold) continue; // too transparent
      final r = px[i], g = px[i + 1], b = px[i + 2];

      // r >> 4 drops the low 4 bits: 0..255 becomes 0..15.
      // Then we pack the three 0..15 numbers into one bucket number:
      //   bucket = r16 * 256 + g16 * 16 + b16
      final bucket =
          ((r >> (8 - _bits)) << (_bits * 2)) |
          ((g >> (8 - _bits)) << _bits) |
          (b >> (8 - _bits));

      counts[bucket]++;
      sumR[bucket] += r;
      sumG[bucket] += g;
      sumB[bucket] += b;
      visible++;
    }
    if (visible == 0) return LogoPalette.empty;

    // ---- Step 2: list the non-empty buckets, biggest first ----------------
    final used = <int>[
      for (var bucket = 0; bucket < _bucketCount; bucket++)
        if (counts[bucket] > 0) bucket,
    ]..sort((a, b) => counts[b].compareTo(counts[a]));

    // ---- Step 3: merge similar buckets into clusters ----------------------
    final clusters = <_Cluster>[];
    for (final bucket in used) {
      final n = counts[bucket];
      final r = sumR[bucket] / n, g = sumG[bucket] / n, b = sumB[bucket] / n;
      final lab = ColorMath.rgb8ToOkLab(r.round(), g.round(), b.round());

      // Find the closest cluster we already have.
      _Cluster? nearest;
      var nearestDistance = double.infinity;
      for (final c in clusters) {
        final d = c.lab.distanceTo(lab);
        if (d < nearestDistance) {
          nearestDistance = d;
          nearest = c;
        }
      }

      final closeEnough = nearestDistance <= options.mergeDistance;
      final full = clusters.length >= options.maxColors;
      if (nearest != null && (closeEnough || full)) {
        nearest.add(n, sumR[bucket], sumG[bucket], sumB[bucket]);
      } else {
        clusters.add(_Cluster(n, sumR[bucket], sumG[bucket], sumB[bucket]));
      }
    }

    // ---- Step 4: turn clusters into swatches ------------------------------
    clusters.sort((a, b) => b.count.compareTo(a.count));
    return LogoPalette([
      for (final c in clusters)
        LogoSwatch(
          color: c.color,
          pixelCount: c.count,
          share: c.count / visible,
        ),
    ], visiblePixels: visible);
  }
}

/// A growing group of similar pixels (internal helper).
class _Cluster {
  _Cluster(this.count, this.sumR, this.sumG, this.sumB) {
    _update();
  }

  int count;
  double sumR, sumG, sumB;
  late OkLab lab;
  late Color color;

  void add(int n, double r, double g, double b) {
    count += n;
    sumR += r;
    sumG += g;
    sumB += b;
    _update();
  }

  // Recompute the average color after every merge, so the next comparison
  // uses the cluster's current center.
  void _update() {
    final r = (sumR / count).round();
    final g = (sumG / count).round();
    final b = (sumB / count).round();
    color = Color.fromARGB(255, r, g, b);
    lab = ColorMath.rgb8ToOkLab(r, g, b);
  }
}

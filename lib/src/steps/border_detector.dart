// =============================================================================
// border_detector.dart  (pipeline step 1)
//
// Question it answers: "Is this logo sitting inside a solid box?"
//
// A JPG can't be transparent, so logos often arrive as a picture of the logo
// on a white (or colored) rectangle. If that is the case, the pixels along
// the OUTER EDGE of the image are almost all the same color.
//
// How it works:
//
//   1. Walk around the image border, `ringWidth` pixels deep.
//   2. Count the transparent pixels. If most of the edge is transparent, the
//      logo is already a cut-out PNG: there is no box to remove.
//   3. Otherwise find the most common edge color (using the same 16-level
//      buckets as the palette step) and average the pixels in that bucket.
//   4. "Uniformity" = the share of edge pixels that look like that color.
//      If it is at least `minUniformity` (default 80%), we call it a box.
// =============================================================================

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../color/color_math.dart';
import '../image/rgba_image.dart';

/// Settings for [BorderDetector].
@immutable
class BorderOptions {
  /// Creates border-detection settings.
  const BorderOptions({
    this.ringWidth = 2,
    this.tolerance = 0.06,
    this.minUniformity = 0.8,
  }) : assert(ringWidth >= 1, 'ringWidth must be at least 1'),
       assert(
         minUniformity > 0 && minUniformity <= 1,
         'minUniformity must be in (0, 1]',
       );

  /// How many pixels deep the sampled edge is.
  final int ringWidth;

  /// Max OKLab distance for an edge pixel to count as "the same color".
  final double tolerance;

  /// Share of edge pixels (0..1) that must match for the edge to be a box.
  final double minUniformity;

  @override
  bool operator ==(Object other) =>
      other is BorderOptions &&
      other.ringWidth == ringWidth &&
      other.tolerance == tolerance &&
      other.minUniformity == minUniformity;

  @override
  int get hashCode => Object.hash(ringWidth, tolerance, minUniformity);
}

/// What [BorderDetector] found.
@immutable
class BorderDetection {
  /// Creates a detection result.
  const BorderDetection({
    required this.color,
    required this.uniformity,
    required this.transparentShare,
    required this.isUniform,
  });

  /// The most common edge color, or null when the edge is transparent.
  final Color? color;

  /// Share (0..1) of opaque edge pixels that match [color].
  final double uniformity;

  /// Share (0..1) of edge pixels that are (almost) fully transparent.
  final double transparentShare;

  /// True when the image sits in a solid box of [color].
  final bool isUniform;

  /// True when the edge is mostly transparent (already a cut-out logo).
  bool get isTransparent => transparentShare >= 0.5;

  @override
  String toString() =>
      'BorderDetection(color: ${color == null ? 'none' : ColorMath.toHex(color!)}, '
      'uniformity: ${uniformity.toStringAsFixed(2)}, '
      'transparent: ${transparentShare.toStringAsFixed(2)}, '
      'isUniform: $isUniform)';
}

/// Detects a solid background box. See the comment at the top of the file.
abstract final class BorderDetector {
  /// Inspects the outer edge of [image].
  static BorderDetection detect(
    RgbaImage image, {
    BorderOptions options = const BorderOptions(),
  }) {
    final px = image.pixels;
    final w = image.width, h = image.height;
    // A ring can't be deeper than half the image.
    final ring = options.ringWidth.clamp(1, (w < h ? w : h) ~/ 2 + 1);

    // ---- Step 1: collect the byte index of every edge pixel ---------------
    final edge = <int>[];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final onEdge = x < ring || y < ring || x >= w - ring || y >= h - ring;
        if (onEdge) edge.add(image.indexOf(x, y));
      }
    }

    // ---- Step 2: transparent pixels + buckets of the opaque ones ----------
    var transparent = 0;
    final opaque = <int>[];
    final counts = Int32List(4096);
    for (final i in edge) {
      if (px[i + 3] < 32) {
        transparent++;
        continue;
      }
      opaque.add(i);
      counts[_bucket(px[i], px[i + 1], px[i + 2])]++;
    }
    final transparentShare = transparent / edge.length;

    if (opaque.isEmpty || transparentShare >= 0.5) {
      return BorderDetection(
        color: null,
        uniformity: 0,
        transparentShare: transparentShare,
        isUniform: false,
      );
    }

    // ---- Step 3: the most common bucket, and its exact average color ------
    var best = 0;
    for (var b = 1; b < counts.length; b++) {
      if (counts[b] > counts[best]) best = b;
    }
    var r = 0, g = 0, bl = 0, n = 0;
    for (final i in opaque) {
      if (_bucket(px[i], px[i + 1], px[i + 2]) == best) {
        r += px[i];
        g += px[i + 1];
        bl += px[i + 2];
        n++;
      }
    }
    final color = Color.fromARGB(
      255,
      (r / n).round(),
      (g / n).round(),
      (bl / n).round(),
    );

    // ---- Step 4: how many edge pixels look like that color? ---------------
    final target = ColorMath.toOkLab(color);
    var matching = 0;
    for (final i in opaque) {
      final lab = ColorMath.rgb8ToOkLab(px[i], px[i + 1], px[i + 2]);
      if (lab.distanceTo(target) <= options.tolerance) matching++;
    }
    final uniformity = matching / opaque.length;

    return BorderDetection(
      color: color,
      uniformity: uniformity,
      transparentShare: transparentShare,
      isUniform: uniformity >= options.minUniformity,
    );
  }

  // Same 16-level bucket idea as in palette_extractor.dart.
  static int _bucket(int r, int g, int b) =>
      ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
}

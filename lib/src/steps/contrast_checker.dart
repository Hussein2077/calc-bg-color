// =============================================================================
// contrast_checker.dart  (pipeline step 5)
//
// Question it answers: "Will this logo be visible on THIS background?"
//
// We check every logo color (swatch) against the background with two tests.
// A swatch "blends in" if it fails EITHER one:
//
//   A. Brightness test: contrast ratio < minContrast
//      Catches light gray on white or navy on black: different hue, but the
//      same brightness, so the edges are hard to see.
//
//   B. Similarity test: OKLab difference < minDifference
//      Catches colors that look almost the same.
//
// Then we add up the shares of the swatches that blend in:
//
//      blendShare = sum of share of every blending swatch
//
// and call it a conflict when blendShare > maxBlendShare (default 12%).
//
// Example: a logo that is 70% blue + 30% white, on a white header:
//   blue  vs white: contrast ~8.7, passes   (blue = #1E40AF)
//   white vs white: contrast 1.0, BLENDS
//   blendShare = 0.30 > 0.12, so it's a CONFLICT (the white part vanishes).
// =============================================================================

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../color/color_math.dart';
import 'palette_extractor.dart';

/// Settings for [ContrastChecker].
@immutable
class ContrastOptions {
  /// Creates contrast settings.
  const ContrastOptions({
    this.minContrast = 2.0,
    this.minDifference = 0.12,
    this.maxBlendShare = 0.12,
    this.significantShare = 0.05,
  });

  /// Below this WCAG contrast ratio a logo color counts as blending in.
  ///
  /// WCAG asks 3.0 for icons. The default 2.0 is a bit softer on purpose:
  /// colorful logos (orange on white is ~2.8) still look fine to people.
  /// Use 3.0 for strict accessibility.
  final double minContrast;

  /// Below this OKLab difference a logo color counts as blending in.
  final double minDifference;

  /// Max share (0..1) of the logo allowed to blend in before it's a conflict.
  final double maxBlendShare;

  /// Swatches smaller than this share are ignored for [ContrastReport.worstContrast]
  /// (so a few anti-aliased pixels don't decide the result).
  final double significantShare;

  @override
  bool operator ==(Object other) =>
      other is ContrastOptions &&
      other.minContrast == minContrast &&
      other.minDifference == minDifference &&
      other.maxBlendShare == maxBlendShare &&
      other.significantShare == significantShare;

  @override
  int get hashCode =>
      Object.hash(minContrast, minDifference, maxBlendShare, significantShare);
}

/// How one logo color does against the background.
@immutable
class SwatchContrast {
  /// Creates a per-swatch result.
  const SwatchContrast({
    required this.swatch,
    required this.contrast,
    required this.difference,
    required this.blends,
  });

  /// The logo color being checked.
  final LogoSwatch swatch;

  /// WCAG contrast ratio against the background (1..21).
  final double contrast;

  /// OKLab difference from the background (0..1).
  final double difference;

  /// True if this color fails the brightness or the similarity test.
  final bool blends;
}

/// The full answer from [ContrastChecker.check].
@immutable
class ContrastReport {
  /// Creates a report.
  const ContrastReport({
    required this.background,
    required this.swatches,
    required this.blendShare,
    required this.worstContrast,
    required this.hasConflict,
  });

  /// The background that was checked.
  final Color background;

  /// One entry per logo color.
  final List<SwatchContrast> swatches;

  /// Share (0..1) of the logo that blends into the background.
  final double blendShare;

  /// The lowest contrast among the significant logo colors.
  final double worstContrast;

  /// True when too much of the logo blends in.
  final bool hasConflict;

  /// A human-readable explanation, handy for debugging or a tooltip.
  String get reason {
    final pct = (blendShare * 100).toStringAsFixed(0);
    final bg = ColorMath.toHex(background);
    return hasConflict
        ? '$pct% of the logo blends into $bg '
              '(lowest contrast ${worstContrast.toStringAsFixed(2)}:1).'
        : 'The logo stands out on $bg '
              '(lowest contrast ${worstContrast.toStringAsFixed(2)}:1).';
  }
}

/// Checks a logo palette against a background. See the top of the file.
abstract final class ContrastChecker {
  /// Checks [palette] against [background].
  static ContrastReport check(
    LogoPalette palette,
    Color background, {
    ContrastOptions options = const ContrastOptions(),
  }) {
    // Only the visible part of a translucent background matters, so treat
    // the background as opaque.
    final bg = background.withValues(alpha: 1);

    final results = <SwatchContrast>[];
    var blendShare = 0.0;
    var worst = 21.0; // start at the best possible value
    var worstAll = 21.0;

    for (final s in palette.swatches) {
      final contrast = ColorMath.contrastRatio(s.color, bg);
      final difference = ColorMath.difference(s.color, bg);
      final blends =
          contrast < options.minContrast || difference < options.minDifference;

      if (blends) blendShare += s.share;
      if (contrast < worstAll) worstAll = contrast;
      if (s.share >= options.significantShare && contrast < worst) {
        worst = contrast;
      }
      results.add(
        SwatchContrast(
          swatch: s,
          contrast: contrast,
          difference: difference,
          blends: blends,
        ),
      );
    }

    // If every swatch was tiny, fall back to the worst of all of them.
    if (worst == 21.0 && palette.swatches.isNotEmpty) worst = worstAll;

    return ContrastReport(
      background: bg,
      swatches: results,
      blendShare: blendShare,
      worstContrast: worst,
      hasConflict: blendShare > options.maxBlendShare,
    );
  }
}

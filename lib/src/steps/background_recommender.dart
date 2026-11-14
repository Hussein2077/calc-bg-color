// =============================================================================
// background_recommender.dart  (pipeline step 6)
//
// Question it answers: "If the logo doesn't fit my background, which
// background should I use instead?"
//
// Other packages pick a color FROM the logo. That often makes it worse: a
// blue logo on a blue backdrop disappears. We do the opposite: try many
// candidate backgrounds and score how well the logo shows on each one.
//
// 1. CANDIDATES (where the options come from):
//      * current     - your current background (we prefer not to change it)
//      * custom      - colors you pass in, e.g. your theme colors
//      * neutral     - white, light gray, dark slate, black
//      * brandTint   - a very light and a very dark version of the logo's
//                      own main color, so the backdrop "matches" the brand
//                      while still giving contrast
//
// 2. SCORE each candidate (0..1, higher is better):
//
//      score = wVisible   * visibleShare      (how much of the logo shows)
//            + wContrast  * contrastScore     (how strong the weakest edge is)
//            + wCloseness * closeness         (how close to your current bg)
//
//      visibleShare  = 1 - blendShare                      (from step 5)
//      contrastScore = (min(worstContrast, 7) - 1) / 6     (1:1 -> 0, 7:1 -> 1)
//      closeness     = 1 - difference(candidate, current)  (same -> 1)
//
//    Contrast is capped at 7:1 because above that, more doesn't look better.
//
// 3. SORT by score, drop near-duplicates, keep the top `maxSuggestions`.
// =============================================================================

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../color/color_math.dart';
import 'contrast_checker.dart';
import 'palette_extractor.dart';

/// Where a suggested background came from.
enum BackgroundSource {
  /// The background you are using now.
  current,

  /// One of [RecommendationOptions.candidates].
  custom,

  /// A neutral color (white, gray, slate, black).
  neutral,

  /// A light or dark tint of the logo's own main color.
  brandTint,
}

/// Settings for [BackgroundRecommender].
@immutable
class RecommendationOptions {
  /// Creates recommendation settings.
  const RecommendationOptions({
    this.candidates = const [],
    this.includeNeutrals = true,
    this.includeBrandTints = true,
    this.maxSuggestions = 5,
    this.visibleWeight = 0.6,
    this.contrastWeight = 0.25,
    this.closenessWeight = 0.15,
  });

  /// Your own colors to consider (for example your theme's surfaces).
  final List<Color> candidates;

  /// Also try white, light gray, dark slate and black.
  final bool includeNeutrals;

  /// Also try light/dark tints of the logo's main color.
  final bool includeBrandTints;

  /// How many suggestions to return.
  final int maxSuggestions;

  /// Weight of "how much of the logo is visible" in the score.
  final double visibleWeight;

  /// Weight of "how strong the weakest contrast is" in the score.
  final double contrastWeight;

  /// Weight of "how close to the current background" in the score.
  final double closenessWeight;

  /// The neutral colors tried when [includeNeutrals] is true.
  static const List<Color> neutrals = [
    Color(0xFFFFFFFF), // white
    Color(0xFFF1F5F9), // light gray
    Color(0xFF0F172A), // dark slate
    Color(0xFF000000), // black
  ];

  @override
  bool operator ==(Object other) =>
      other is RecommendationOptions &&
      listEquals(other.candidates, candidates) &&
      other.includeNeutrals == includeNeutrals &&
      other.includeBrandTints == includeBrandTints &&
      other.maxSuggestions == maxSuggestions &&
      other.visibleWeight == visibleWeight &&
      other.contrastWeight == contrastWeight &&
      other.closenessWeight == closenessWeight;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(candidates),
    includeNeutrals,
    includeBrandTints,
    maxSuggestions,
    visibleWeight,
    contrastWeight,
    closenessWeight,
  );
}

/// One scored background option.
@immutable
class BackgroundSuggestion {
  /// Creates a suggestion.
  const BackgroundSuggestion({
    required this.color,
    required this.source,
    required this.score,
    required this.report,
  });

  /// The background color.
  final Color color;

  /// Where this candidate came from.
  final BackgroundSource source;

  /// 0..1, higher is better.
  final double score;

  /// The full contrast check of the logo on [color].
  final ContrastReport report;

  @override
  String toString() =>
      'BackgroundSuggestion(${ColorMath.toHex(color)}, ${source.name}, '
      'score: ${score.toStringAsFixed(3)})';
}

/// Scores candidate backgrounds. See the comment at the top of the file.
abstract final class BackgroundRecommender {
  /// Returns the best backgrounds for [palette], best first.
  static List<BackgroundSuggestion> recommend(
    LogoPalette palette, {
    required Color current,
    ContrastOptions contrast = const ContrastOptions(),
    RecommendationOptions options = const RecommendationOptions(),
  }) {
    final currentOpaque = current.withValues(alpha: 1);

    // ---- 1. Collect candidates --------------------------------------------
    final candidates = <(Color, BackgroundSource)>[
      (currentOpaque, BackgroundSource.current),
      for (final c in options.candidates) (c, BackgroundSource.custom),
      if (options.includeNeutrals)
        for (final c in RecommendationOptions.neutrals)
          (c, BackgroundSource.neutral),
      if (options.includeBrandTints && palette.dominant != null) ...[
        // Very light: lightness 0.96, with a little of the brand color.
        (
          ColorMath.withLightness(
            palette.dominant!.color,
            0.96,
            chromaScale: 0.3,
          ),
          BackgroundSource.brandTint,
        ),
        // Very dark: lightness 0.25, same idea.
        (
          ColorMath.withLightness(
            palette.dominant!.color,
            0.25,
            chromaScale: 0.5,
          ),
          BackgroundSource.brandTint,
        ),
      ],
    ];

    // ---- 2. Score each one ------------------------------------------------
    final scored = <BackgroundSuggestion>[];
    for (final (color, source) in candidates) {
      final report = ContrastChecker.check(palette, color, options: contrast);
      final visibleShare = 1 - report.blendShare;
      final contrastScore = (report.worstContrast.clamp(1.0, 7.0) - 1) / 6;
      final closeness =
          1 - ColorMath.difference(color, currentOpaque).clamp(0.0, 1.0);

      final score =
          options.visibleWeight * visibleShare +
          options.contrastWeight * contrastScore +
          options.closenessWeight * closeness;

      scored.add(
        BackgroundSuggestion(
          color: color,
          source: source,
          score: score,
          report: report,
        ),
      );
    }

    // ---- 3. Sort, remove near-duplicates, cut to size ---------------------
    // Sorting is stable, so on a tie "current" (added first) stays first.
    scored.sort((a, b) => b.score.compareTo(a.score));
    final result = <BackgroundSuggestion>[];
    for (final s in scored) {
      final duplicate = result.any(
        (r) => ColorMath.difference(r.color, s.color) < 0.02,
      );
      if (!duplicate) result.add(s);
      if (result.length >= options.maxSuggestions) break;
    }
    return result;
  }
}

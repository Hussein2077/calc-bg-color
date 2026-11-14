// =============================================================================
// logo_pipeline.dart
//
// Runs all the steps in order. Pure Dart: give it pixels, get answers.
//
//   RgbaImage (raw pixels)
//      |
//      | 1. BorderDetector       is it inside a solid box?
//      | 2. BackgroundRemover    if yes, make the box transparent
//      | 3. Trimmer              cut empty margins
//      | 4. PaletteExtractor     which colors is the logo made of?
//      v
//   LogoReport   <- depends only on the IMAGE, compute once per logo
//      |
//      | 5. ContrastChecker      does it blend into my background?
//      | 6. BackgroundRecommender  what should the background be?
//      v
//   LogoEvaluation  <- depends on the BACKGROUND, cheap, redo on theme change
//
// The split matters: steps 1-4 touch every pixel (slow-ish), steps 5-6 only
// look at ~6 colors (instant). When the user switches light/dark mode you
// only redo steps 5-6.
// =============================================================================

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../color/color_math.dart';
import '../image/rgba_image.dart';
import '../steps/background_recommender.dart';
import '../steps/background_remover.dart';
import '../steps/border_detector.dart';
import '../steps/contrast_checker.dart';
import '../steps/palette_extractor.dart';
import '../steps/trimmer.dart';

/// Settings for the image steps (1-4). Every field has a default.
@immutable
class LogoOptions {
  /// Creates image-processing settings.
  const LogoOptions({
    this.maxDimension = 400,
    this.removeBackground = true,
    this.border = const BorderOptions(),
    this.removal = const RemovalOptions(),
    this.trim = const TrimOptions(),
    this.palette = const PaletteOptions(),
  }) : assert(maxDimension >= 16, 'maxDimension must be at least 16');

  /// The image is shrunk so its longest side is at most this many pixels
  /// before processing. Smaller = faster; 400 keeps logos sharp.
  final int maxDimension;

  /// Set to false to never remove a solid background box.
  final bool removeBackground;

  /// Step 1 settings.
  final BorderOptions border;

  /// Step 2 settings.
  final RemovalOptions removal;

  /// Step 3 settings.
  final TrimOptions trim;

  /// Step 4 settings.
  final PaletteOptions palette;

  @override
  bool operator ==(Object other) =>
      other is LogoOptions &&
      other.maxDimension == maxDimension &&
      other.removeBackground == removeBackground &&
      other.border == border &&
      other.removal == removal &&
      other.trim == trim &&
      other.palette == palette;

  @override
  int get hashCode => Object.hash(
    maxDimension,
    removeBackground,
    border,
    removal,
    trim,
    palette,
  );
}

/// Everything learned from the image itself (steps 1-4).
@immutable
class LogoReport {
  /// Creates a report. Normally made by [LogoPipeline.run].
  const LogoReport({
    required this.cleaned,
    required this.border,
    required this.removedPixels,
    required this.palette,
  });

  /// The logo after background removal and trimming.
  final RgbaImage cleaned;

  /// What step 1 found on the image edge.
  final BorderDetection border;

  /// Pixels made transparent in step 2 (0 if nothing was removed).
  final int removedPixels;

  /// The logo's colors (step 4).
  final LogoPalette palette;

  /// True when a solid background box was found and removed.
  bool get backgroundRemoved => removedPixels > 0;

  /// Runs steps 5-6 for [background].
  LogoEvaluation evaluate(
    Color background, {
    ContrastOptions contrast = const ContrastOptions(),
    RecommendationOptions recommendation = const RecommendationOptions(),
  }) {
    final report = ContrastChecker.check(
      palette,
      background,
      options: contrast,
    );
    final suggestions = BackgroundRecommender.recommend(
      palette,
      current: background,
      contrast: contrast,
      options: recommendation,
    );
    return LogoEvaluation(
      contrast: report,
      suggestions: suggestions,
      // Keep the current background unless there is a real conflict.
      recommendedBackground: report.hasConflict && suggestions.isNotEmpty
          ? suggestions.first.color
          : background,
      // A halo must stand out against the BACKGROUND, so pick black or
      // white, whichever has more contrast with it.
      haloColor: ColorMath.readableOn(background),
    );
  }
}

/// The answer for one logo on one background (steps 5-6).
@immutable
class LogoEvaluation {
  /// Creates an evaluation. Normally made by [LogoReport.evaluate].
  const LogoEvaluation({
    required this.contrast,
    required this.suggestions,
    required this.recommendedBackground,
    required this.haloColor,
  });

  /// The contrast check against the current background.
  final ContrastReport contrast;

  /// Scored alternative backgrounds, best first.
  final List<BackgroundSuggestion> suggestions;

  /// The current background if there's no conflict, otherwise the best
  /// suggestion.
  final Color recommendedBackground;

  /// Color for an outline halo that makes the logo visible on the current
  /// background.
  final Color haloColor;

  /// Shortcut for `contrast.hasConflict`.
  bool get hasConflict => contrast.hasConflict;
}

/// Runs steps 1-4. See the diagram at the top of the file.
abstract final class LogoPipeline {
  /// Processes [image] and returns a [LogoReport].
  static LogoReport run(
    RgbaImage image, {
    LogoOptions options = const LogoOptions(),
  }) {
    // 1. Look at the edge.
    final border = BorderDetector.detect(image, options: options.border);

    // 2. Remove the box, only if the edge really is one solid color.
    var working = image;
    var removed = 0;
    final boxColor = border.color;
    if (options.removeBackground && border.isUniform && boxColor != null) {
      final result = BackgroundRemover.remove(
        image,
        boxColor,
        options: options.removal,
      );
      working = result.image;
      removed = result.removedPixels;
    }

    // 3. Cut empty margins.
    if (options.trim.enabled) {
      working = Trimmer.trim(working, options: options.trim);
    }

    // 4. Find the colors of what is left.
    final palette = PaletteExtractor.extract(working, options: options.palette);

    return LogoReport(
      cleaned: working,
      border: border,
      removedPixels: removed,
      palette: palette,
    );
  }
}

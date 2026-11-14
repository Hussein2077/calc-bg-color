// =============================================================================
// adaptive_logo.dart
//
// The one-widget way to use the package:
//
//   AdaptiveLogo(
//     image: NetworkImage(url),
//     background: Theme.of(context).colorScheme.surface,
//     width: 160,
//   )
//
// What happens inside:
//
//   initState / image changed   -> LogoAnalyzer.prepare(image)  (slow part,
//                                  runs once per logo, cached)
//   every build                 -> prepared.evaluate(background) (instant)
//   then, depending on `effect`:
//     none           show the cleaned logo
//     halo           add an outline when the logo blends in   (default)
//     backdrop       put it on the recommended color when it blends in
//     alwaysBackdrop always put it on the best-scoring color
//
// While loading, or if loading fails (e.g. CORS on web), the original image
// is shown, so the user never sees an empty box.
// =============================================================================

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../flutter/logo_analyzer.dart';
import '../pipeline/logo_pipeline.dart';
import '../steps/background_recommender.dart';
import '../steps/contrast_checker.dart';
import 'logo_halo.dart';

/// How [AdaptiveLogo] reacts to the evaluation.
enum AdaptiveLogoEffect {
  /// Only show the cleaned logo.
  none,

  /// Add a shape-following outline when the logo blends in.
  halo,

  /// Place the logo on the recommended background when it blends in.
  backdrop,

  /// Always place the logo on the best-scoring background.
  alwaysBackdrop,
}

/// Shows a logo cleaned up and adapted to [background].
class AdaptiveLogo extends StatefulWidget {
  /// Creates an adaptive logo.
  const AdaptiveLogo({
    super.key,
    required this.image,
    required this.background,
    this.width = 160,
    this.height,
    this.effect = AdaptiveLogoEffect.halo,
    this.options = const LogoOptions(),
    this.contrast = const ContrastOptions(),
    this.recommendation = const RecommendationOptions(),
    this.haloStyle = const LogoHaloStyle(),
    this.backdropPadding = const EdgeInsets.all(12),
    this.backdropRadius = const BorderRadius.all(Radius.circular(12)),
    this.onEvaluated,
  });

  /// The logo: NetworkImage, AssetImage, MemoryImage, ...
  final ImageProvider image;

  /// The color the logo will be drawn on (your header, card, ...).
  final Color background;

  /// Fixed width of the logo.
  final double width;

  /// Optional fixed height. If null, the logo keeps its aspect ratio.
  final double? height;

  /// What to do when the logo blends into [background].
  final AdaptiveLogoEffect effect;

  /// Image-processing settings (steps 1-4).
  final LogoOptions options;

  /// Contrast settings (step 5).
  final ContrastOptions contrast;

  /// Recommendation settings (step 6).
  final RecommendationOptions recommendation;

  /// Look of the halo for [AdaptiveLogoEffect.halo].
  final LogoHaloStyle haloStyle;

  /// Space between the logo and the backdrop edge.
  final EdgeInsets backdropPadding;

  /// Corner radius of the backdrop.
  final BorderRadius backdropRadius;

  /// Called after each new evaluation, for example to show the
  /// recommendation elsewhere in your UI.
  final ValueChanged<LogoEvaluation>? onEvaluated;

  @override
  State<AdaptiveLogo> createState() => _AdaptiveLogoState();
}

class _AdaptiveLogoState extends State<AdaptiveLogo> {
  late Future<PreparedLogo> _future;
  Object? _lastReported; // to call onEvaluated only when something changed

  @override
  void initState() {
    super.initState();
    _future = LogoAnalyzer.prepare(widget.image, options: widget.options);
  }

  @override
  void didUpdateWidget(AdaptiveLogo old) {
    super.didUpdateWidget(old);
    // Only redo the slow part when the image or image settings change.
    // A new background does NOT need it: evaluate() in build is enough.
    if (old.image != widget.image || old.options != widget.options) {
      _future = LogoAnalyzer.prepare(widget.image, options: widget.options);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PreparedLogo>(
      future: _future,
      builder: (context, snapshot) {
        final logo = snapshot.data;
        if (logo == null) {
          // Loading or failed: show the original image as a fallback.
          return Image(
            image: widget.image,
            width: widget.width,
            height: widget.height,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) =>
                SizedBox(width: widget.width, height: widget.height),
          );
        }

        final evaluation = logo.evaluate(
          widget.background,
          contrast: widget.contrast,
          recommendation: widget.recommendation,
        );
        _report(logo, evaluation);
        return _buildLogo(logo, evaluation);
      },
    );
  }

  Widget _buildLogo(PreparedLogo logo, LogoEvaluation evaluation) {
    final image = Image.memory(
      logo.pngBytes,
      width: widget.width,
      height: widget.height,
      fit: BoxFit.contain,
      gaplessPlayback: true, // no flicker when the bytes change
    );

    switch (widget.effect) {
      case AdaptiveLogoEffect.none:
        return image;
      case AdaptiveLogoEffect.halo:
        if (!evaluation.hasConflict) return image;
        return LogoHalo(
          color: evaluation.haloColor,
          style: widget.haloStyle,
          child: image,
        );
      case AdaptiveLogoEffect.backdrop:
        if (!evaluation.hasConflict) return image;
        return _backdrop(evaluation.recommendedBackground, image);
      case AdaptiveLogoEffect.alwaysBackdrop:
        final best = evaluation.suggestions.isEmpty
            ? evaluation.recommendedBackground
            : evaluation.suggestions.first.color;
        return _backdrop(best, image);
    }
  }

  Widget _backdrop(Color color, Widget child) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: widget.backdropRadius,
    ),
    child: Padding(padding: widget.backdropPadding, child: child),
  );

  // Calls onEvaluated after the frame (never during build), and only when
  // the inputs changed, to avoid a setState -> build -> callback loop.
  void _report(PreparedLogo logo, LogoEvaluation evaluation) {
    final callback = widget.onEvaluated;
    if (callback == null) return;
    final key = (
      logo,
      widget.background,
      widget.contrast,
      widget.recommendation,
    );
    if (key == _lastReported) return;
    _lastReported = key;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback(evaluation);
    });
  }
}

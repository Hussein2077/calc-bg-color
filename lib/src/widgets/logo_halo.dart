// =============================================================================
// logo_halo.dart
//
// Draws an outline that hugs the SHAPE of the logo (not a rectangle).
//
// How, layer by layer (bottom to top):
//
//   1. Take the logo and paint every visible pixel in one color:
//        ColorFilter.mode(haloColor, BlendMode.srcIn)
//      "srcIn" = keep the shape (alpha) of the image but use our color.
//      Now we have a silhouette.
//   2. Draw that silhouette 8 times, shifted by `spread` pixels in every
//      direction (up, down, left, right and the 4 diagonals). Together they
//      form a silhouette that is slightly BIGGER than the logo.
//   3. Blur it, so the outline is soft instead of jagged.
//   4. Draw the real logo on top.
//
// Result: a thin glow around the logo's letters and icons.
// =============================================================================

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Look of a [LogoHalo].
@immutable
class LogoHaloStyle {
  /// Creates a halo style.
  const LogoHaloStyle({this.spread = 1.5, this.blur = 1.5, this.opacity = 0.9});

  /// How far (logical pixels) the outline reaches beyond the logo.
  final double spread;

  /// Blur radius (sigma) of the outline.
  final double blur;

  /// Opacity of the outline, 0..1.
  final double opacity;

  @override
  bool operator ==(Object other) =>
      other is LogoHaloStyle &&
      other.spread == spread &&
      other.blur == blur &&
      other.opacity == opacity;

  @override
  int get hashCode => Object.hash(spread, blur, opacity);
}

/// Wraps [child] (normally an image) in a shape-following outline.
class LogoHalo extends StatelessWidget {
  /// Creates a halo around [child].
  const LogoHalo({
    super.key,
    required this.color,
    required this.child,
    this.style = const LogoHaloStyle(),
  });

  /// Outline color.
  final Color color;

  /// Look of the outline.
  final LogoHaloStyle style;

  /// The logo.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Step 1: the silhouette.
    final silhouette = ColorFiltered(
      colorFilter: ColorFilter.mode(
        color.withValues(alpha: color.a * style.opacity),
        BlendMode.srcIn,
      ),
      child: child,
    );

    // Step 2: 8 shifted copies, one every 45 degrees.
    final copies = <Widget>[
      for (var i = 0; i < 8; i++)
        Transform.translate(
          offset: Offset(
            math.cos(i * math.pi / 4) * style.spread,
            math.sin(i * math.pi / 4) * style.spread,
          ),
          child: silhouette,
        ),
    ];

    return Stack(
      alignment: Alignment.center,
      children: [
        // Step 3: blur all copies together.
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: style.blur,
            sigmaY: style.blur,
          ),
          child: Stack(alignment: Alignment.center, children: copies),
        ),
        // Step 4: the real logo on top.
        child,
      ],
    );
  }
}

// =============================================================================
// background_remover.dart  (pipeline step 2)
//
// Question it answers: "Turn the solid box around the logo transparent."
//
// For every pixel we measure how different it looks from the box color
// (OKLab distance, called `d` below) and decide:
//
//      d <= tolerance                    -> background: alpha = 0
//      tolerance < d < tolerance+feather -> edge: partly transparent
//      d >= tolerance + feather          -> logo: keep as it is
//
// FEATHERING: logo edges are anti-aliased, meaning the pixels between the
// logo and the box are a blend of both. If we only had "keep" or "delete",
// those pixels would leave a jagged, light fringe. Instead their alpha is
// scaled smoothly from 0 to 255 across the feather band.
//
// FLOOD FILL (the default) vs GLOBAL:
//
//   Imagine a blue circle with a WHITE letter inside, on a white box.
//   * GLOBAL removal deletes every white pixel, so the letter disappears.
//   * FLOOD FILL starts at the image edge and only spreads through
//     neighbouring background pixels, like paint poured from outside.
//     It can't cross the blue ring, so the white letter inside survives.
// =============================================================================

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../color/color_math.dart';
import '../image/rgba_image.dart';

/// Settings for [BackgroundRemover].
@immutable
class RemovalOptions {
  /// Creates background-removal settings.
  const RemovalOptions({
    this.tolerance = 0.08,
    this.feather = 0.06,
    this.floodFill = true,
  }) : assert(tolerance >= 0, 'tolerance must be >= 0'),
       assert(feather >= 0, 'feather must be >= 0');

  /// Pixels closer than this to the box color (OKLab) become transparent.
  final double tolerance;

  /// Width of the soft edge band after [tolerance]. 0 = hard edges.
  final double feather;

  /// true: only remove background connected to the image edge (keeps white
  /// shapes inside the logo). false: remove every matching pixel.
  final bool floodFill;

  @override
  bool operator ==(Object other) =>
      other is RemovalOptions &&
      other.tolerance == tolerance &&
      other.feather == feather &&
      other.floodFill == floodFill;

  @override
  int get hashCode => Object.hash(tolerance, feather, floodFill);
}

/// The output of [BackgroundRemover.remove].
@immutable
class RemovalResult {
  /// Creates a removal result.
  const RemovalResult(this.image, this.removedPixels);

  /// A new image with the background made transparent.
  final RgbaImage image;

  /// How many pixels became fully transparent.
  final int removedPixels;
}

/// Makes a solid background transparent. See the comment at the top.
abstract final class BackgroundRemover {
  /// Removes [background] from a copy of [image].
  static RemovalResult remove(
    RgbaImage image,
    Color background, {
    RemovalOptions options = const RemovalOptions(),
  }) {
    final out = image.copy(); // never modify the caller's image
    final px = out.pixels;
    final bg = ColorMath.toOkLab(background);
    var removed = 0;

    // Decides what happens to one pixel. Returns true if it was background
    // (fully removed), which tells the flood fill to keep spreading.
    bool process(int i) {
      if (px[i + 3] == 0) return true; // already transparent: pass through
      final d = ColorMath.rgb8ToOkLab(
        px[i],
        px[i + 1],
        px[i + 2],
      ).distanceTo(bg);

      if (d <= options.tolerance) {
        px[i + 3] = 0;
        removed++;
        return true;
      }
      final featherEnd = options.tolerance + options.feather;
      if (options.feather > 0 && d < featherEnd) {
        // t goes from 0 (at tolerance) to 1 (at featherEnd).
        final t = (d - options.tolerance) / options.feather;
        px[i + 3] = (px[i + 3] * t).round();
      }
      return false;
    }

    if (!options.floodFill) {
      for (var i = 0; i < px.length; i += 4) {
        process(i);
      }
      return RemovalResult(out, removed);
    }

    // ---- Flood fill -------------------------------------------------------
    final w = out.width, h = out.height;
    final visited = Uint8List(w * h); // 1 = already looked at this pixel
    final stack = <int>[]; // pixel numbers (y * w + x) still to visit

    void push(int x, int y) {
      if (x < 0 || y < 0 || x >= w || y >= h) return; // outside the image
      final p = y * w + x;
      if (visited[p] == 1) return;
      visited[p] = 1;
      stack.add(p);
    }

    // Start from every pixel on the outer edge: "pour paint from outside".
    for (var x = 0; x < w; x++) {
      push(x, 0);
      push(x, h - 1);
    }
    for (var y = 0; y < h; y++) {
      push(0, y);
      push(w - 1, y);
    }

    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      final isBackground = process(p * 4);
      if (!isBackground) continue; // hit the logo (or its edge): stop here
      final x = p % w, y = p ~/ w;
      push(x + 1, y); // right
      push(x - 1, y); // left
      push(x, y + 1); // down
      push(x, y - 1); // up
    }
    return RemovalResult(out, removed);
  }
}

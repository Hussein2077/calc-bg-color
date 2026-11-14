// =============================================================================
// trimmer.dart  (pipeline step 3)
//
// Question it answers: "Cut away the empty margins around the logo."
//
// Why: if you show logos at a fixed width (say 160 px), a logo with a big
// empty margin looks tiny next to one without. After trimming, every logo's
// real artwork fills the width the same way.
//
// How: find the smallest rectangle that contains every visible pixel
// (alpha >= alphaThreshold), add optional padding, and copy that rectangle
// into a new image, row by row.
// =============================================================================

import 'package:flutter/foundation.dart';

import '../image/rgba_image.dart';

/// Settings for [Trimmer].
@immutable
class TrimOptions {
  /// Creates trim settings.
  const TrimOptions({
    this.enabled = true,
    this.alphaThreshold = 16,
    this.padding = 0,
  }) : assert(padding >= 0, 'padding must be >= 0');

  /// Set to false to skip trimming.
  final bool enabled;

  /// Pixels with alpha below this count as empty.
  final int alphaThreshold;

  /// Pixels of empty space to keep around the logo.
  final int padding;

  @override
  bool operator ==(Object other) =>
      other is TrimOptions &&
      other.enabled == enabled &&
      other.alphaThreshold == alphaThreshold &&
      other.padding == padding;

  @override
  int get hashCode => Object.hash(enabled, alphaThreshold, padding);
}

/// Crops transparent margins. See the comment at the top of the file.
abstract final class Trimmer {
  /// Returns a cropped copy of [image], or [image] itself if nothing is
  /// visible or there is nothing to cut.
  static RgbaImage trim(
    RgbaImage image, {
    TrimOptions options = const TrimOptions(),
  }) {
    final px = image.pixels;
    final w = image.width, h = image.height;

    // Start with an "inside-out" box and grow it around each visible pixel.
    var minX = w, minY = h, maxX = -1, maxY = -1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (px[(y * w + x) * 4 + 3] >= options.alphaThreshold) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < 0) return image; // nothing visible

    // Add padding but stay inside the image.
    final p = options.padding;
    minX = (minX - p).clamp(0, w - 1);
    minY = (minY - p).clamp(0, h - 1);
    maxX = (maxX + p).clamp(0, w - 1);
    maxY = (maxY + p).clamp(0, h - 1);

    final newW = maxX - minX + 1;
    final newH = maxY - minY + 1;
    if (newW == w && newH == h) return image;

    // Copy one row at a time: a row is a continuous run of bytes.
    final out = Uint8List(newW * newH * 4);
    for (var y = 0; y < newH; y++) {
      final from = ((minY + y) * w + minX) * 4;
      out.setRange(y * newW * 4, (y + 1) * newW * 4, px, from);
    }
    return RgbaImage(newW, newH, out);
  }
}

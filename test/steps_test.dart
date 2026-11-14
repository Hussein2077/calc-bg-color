// Tests for every step, using small images built in memory.
// No image files and no network needed.

import 'dart:ui';

import 'package:calc_bg_color/calc_bg_color.dart';
import 'package:flutter_test/flutter_test.dart';

const white = Color(0xFFFFFFFF);
const blue = Color(0xFF1E40AF);
const red = Color(0xFFDC2626);
const clear = Color(0x00000000);

/// A 40x40 "JPG logo": white box, blue square ring (x/y 10..29) and a
/// white hole in the middle of the ring (x/y 15..24).
RgbaImage ringOnWhiteBox() {
  final img = RgbaImage.filled(40, 40, white);
  img.fillRect(10, 10, 20, 20, blue);
  img.fillRect(15, 15, 10, 10, white);
  return img;
}

void main() {
  group('BorderDetector', () {
    test('finds a white box', () {
      final result = BorderDetector.detect(ringOnWhiteBox());
      expect(result.isUniform, isTrue);
      expect(result.color, white);
      expect(result.isTransparent, isFalse);
    });

    test('a transparent edge is not a box', () {
      final img = RgbaImage.filled(20, 20, clear)..fillRect(5, 5, 10, 10, blue);
      final result = BorderDetector.detect(img);
      expect(result.isTransparent, isTrue);
      expect(result.isUniform, isFalse);
    });

    test('a busy edge is not uniform', () {
      final img = RgbaImage.filled(20, 20, white);
      // Paint the left half of the image red.
      img.fillRect(0, 0, 10, 20, red);
      expect(BorderDetector.detect(img).isUniform, isFalse);
    });
  });

  group('BackgroundRemover', () {
    test('flood fill keeps the white hole inside the logo', () {
      final out = BackgroundRemover.remove(ringOnWhiteBox(), white).image;
      expect(out.alphaAt(0, 0), 0, reason: 'outside box is removed');
      expect(out.alphaAt(12, 12), 255, reason: 'blue ring stays');
      expect(out.alphaAt(20, 20), 255, reason: 'white hole stays');
    });

    test('global mode also removes the white hole', () {
      final out = BackgroundRemover.remove(
        ringOnWhiteBox(),
        white,
        options: const RemovalOptions(floodFill: false),
      ).image;
      expect(out.alphaAt(20, 20), 0);
      expect(out.alphaAt(12, 12), 255);
    });

    test('feathering makes in-between colors half transparent', () {
      final img = RgbaImage.filled(5, 1, white);
      // A light gray, slightly different from white.
      img.setColor(2, 0, const Color(0xFFD9D9D9));
      final out = BackgroundRemover.remove(
        img,
        white,
        options: const RemovalOptions(floodFill: false),
      ).image;
      final a = out.alphaAt(2, 0);
      expect(a, greaterThan(0));
      expect(a, lessThan(255));
    });

    test('does not change the input image', () {
      final input = ringOnWhiteBox();
      BackgroundRemover.remove(input, white);
      expect(input.alphaAt(0, 0), 255);
    });
  });

  group('Trimmer', () {
    test('crops to the visible pixels', () {
      final img = RgbaImage.filled(40, 40, clear)..fillRect(10, 5, 20, 8, blue);
      final out = Trimmer.trim(img);
      expect(out.width, 20);
      expect(out.height, 8);
    });

    test('padding is added but stays inside the image', () {
      final img = RgbaImage.filled(40, 40, clear)..fillRect(1, 1, 10, 10, blue);
      final out = Trimmer.trim(img, options: const TrimOptions(padding: 3));
      expect(out.width, 10 + 1 + 3); // only 1 px free on the left
      expect(out.height, 10 + 1 + 3);
    });

    test('a fully transparent image is returned unchanged', () {
      final img = RgbaImage.filled(10, 10, clear);
      expect(identical(Trimmer.trim(img), img), isTrue);
    });
  });

  group('PaletteExtractor', () {
    test('finds two colors and their shares', () {
      final img = RgbaImage.filled(10, 10, blue)..fillRect(0, 0, 10, 3, red);
      final palette = PaletteExtractor.extract(img);
      expect(palette.swatches, hasLength(2));
      expect(palette.dominant!.color, blue);
      expect(palette.swatches[0].share, closeTo(0.7, 1e-9));
      expect(palette.swatches[1].color, red);
      expect(palette.swatches[1].share, closeTo(0.3, 1e-9));
    });

    test('ignores transparent pixels', () {
      final img = RgbaImage.filled(10, 10, clear)..fillRect(0, 0, 5, 5, blue);
      final palette = PaletteExtractor.extract(img);
      expect(palette.visiblePixels, 25);
      expect(palette.swatches.single.share, 1);
    });

    test('merges near-identical colors', () {
      final img = RgbaImage.filled(10, 10, blue)
        ..fillRect(0, 0, 10, 5, const Color(0xFF1F41B0)); // tiny difference
      expect(PaletteExtractor.extract(img).swatches, hasLength(1));
    });

    test('empty image gives an empty palette', () {
      final palette = PaletteExtractor.extract(RgbaImage.filled(4, 4, clear));
      expect(palette.isEmpty, isTrue);
      expect(palette.dominant, isNull);
    });
  });

  group('ContrastChecker', () {
    LogoPalette paletteOf(List<(Color, double)> parts) => LogoPalette([
      for (final (c, share) in parts)
        LogoSwatch(color: c, pixelCount: (share * 100).round(), share: share),
    ], visiblePixels: 100);

    test('blue logo on white: no conflict', () {
      final report = ContrastChecker.check(paletteOf([(blue, 1)]), white);
      expect(report.hasConflict, isFalse);
      expect(report.blendShare, 0);
    });

    test('blue + 30% white logo on white: conflict', () {
      final report = ContrastChecker.check(
        paletteOf([(blue, 0.7), (white, 0.3)]),
        white,
      );
      expect(report.hasConflict, isTrue);
      expect(report.blendShare, closeTo(0.3, 1e-9));
      expect(report.worstContrast, closeTo(1, 1e-9));
    });

    test('a tiny blending part (5%) is tolerated', () {
      final report = ContrastChecker.check(
        paletteOf([(blue, 0.95), (white, 0.05)]),
        white,
      );
      expect(report.hasConflict, isFalse);
    });
  });

  group('BackgroundRecommender', () {
    test('white logo on white: recommends a dark background', () {
      const palette = LogoPalette([
        LogoSwatch(color: white, pixelCount: 100, share: 1),
      ], visiblePixels: 100);
      final best = BackgroundRecommender.recommend(
        palette,
        current: white,
      ).first;
      expect(ColorMath.luminance(best.color), lessThan(0.1));
      expect(best.report.hasConflict, isFalse);
    });

    test('keeps the current background when it already works', () {
      const palette = LogoPalette([
        LogoSwatch(color: blue, pixelCount: 100, share: 1),
      ], visiblePixels: 100);
      final best = BackgroundRecommender.recommend(
        palette,
        current: white,
      ).first;
      expect(best.source, BackgroundSource.current);
    });

    test('custom candidates are used', () {
      const brandGreen = Color(0xFF14532D);
      const palette = LogoPalette([
        LogoSwatch(color: white, pixelCount: 100, share: 1),
      ], visiblePixels: 100);
      final list = BackgroundRecommender.recommend(
        palette,
        current: white,
        options: const RecommendationOptions(
          candidates: [brandGreen],
          includeNeutrals: false,
          includeBrandTints: false,
        ),
      );
      expect(list.first.color, brandGreen);
    });
  });

  group('LogoPipeline', () {
    test('end to end: JPG-style logo on a white header', () {
      final report = LogoPipeline.run(ringOnWhiteBox());
      expect(report.backgroundRemoved, isTrue);
      // Trimmed to the 20x20 ring.
      expect(report.cleaned.width, 20);
      expect(report.cleaned.height, 20);
      // Ring = 400 - 100 = 300 blue px, hole = 100 white px.
      expect(report.palette.dominant!.color, blue);
      expect(report.palette.swatches[1].share, closeTo(0.25, 1e-9));

      final onWhite = report.evaluate(white);
      expect(onWhite.hasConflict, isTrue, reason: 'white hole vanishes');
      expect(onWhite.recommendedBackground, isNot(white));
      expect(onWhite.haloColor, const Color(0xFF000000));

      final onBlue = report.evaluate(blue);
      expect(onBlue.hasConflict, isTrue, reason: 'blue ring vanishes');
    });

    test('removeBackground: false keeps the box', () {
      final report = LogoPipeline.run(
        ringOnWhiteBox(),
        options: const LogoOptions(removeBackground: false),
      );
      expect(report.backgroundRemoved, isFalse);
      expect(report.cleaned.width, 40);
    });
  });
}

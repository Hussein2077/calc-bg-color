import 'dart:ui';

import 'package:calc_bg_color/calc_bg_color.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const white = Color(0xFFFFFFFF);
  const black = Color(0xFF000000);
  const blue = Color(0xFF1E40AF);

  group('luminance', () {
    test('white is 1 and black is 0', () {
      expect(ColorMath.luminance(white), closeTo(1, 1e-9));
      expect(ColorMath.luminance(black), closeTo(0, 1e-9));
    });

    test('matches Flutter computeLuminance', () {
      for (final c in [blue, const Color(0xFFF97316), const Color(0xFF808080)]) {
        expect(ColorMath.luminance(c), closeTo(c.computeLuminance(), 1e-6));
      }
    });
  });

  group('contrastRatio', () {
    test('black on white is 21:1, same color is 1:1', () {
      expect(ColorMath.contrastRatio(black, white), closeTo(21, 1e-9));
      expect(ColorMath.contrastRatio(blue, blue), closeTo(1, 1e-9));
    });

    test('order does not matter', () {
      expect(
        ColorMath.contrastRatio(blue, white),
        closeTo(ColorMath.contrastRatio(white, blue), 1e-12),
      );
    });

    test('blue #1E40AF on white is about 8.7', () {
      expect(ColorMath.contrastRatio(blue, white), closeTo(8.72, 0.05));
    });
  });

  group('OKLab', () {
    test('white has lightness 1, black 0', () {
      expect(ColorMath.toOkLab(white).l, closeTo(1, 1e-4));
      expect(ColorMath.toOkLab(black).l, closeTo(0, 1e-4));
    });

    test('round trip keeps the color', () {
      for (final c in [blue, const Color(0xFFF97316), const Color(0xFF22C55E)]) {
        final back = ColorMath.fromOkLab(ColorMath.toOkLab(c));
        expect(back.toARGB32(), c.toARGB32());
      }
    });

    test('difference: black vs white is 1, color vs itself is 0', () {
      expect(ColorMath.difference(black, white), closeTo(1, 1e-3));
      expect(ColorMath.difference(blue, blue), 0);
    });

    test('rgb8ToOkLab equals toOkLab', () {
      final a = ColorMath.rgb8ToOkLab(0x1E, 0x40, 0xAF);
      final b = ColorMath.toOkLab(blue);
      expect(a.distanceTo(b), closeTo(0, 1e-9));
    });
  });

  test('readableOn picks white on dark and black on light', () {
    expect(ColorMath.readableOn(blue), white);
    expect(ColorMath.readableOn(const Color(0xFFFDE68A)), black);
  });

  test('toHex', () {
    expect(ColorMath.toHex(blue), '#1E40AF');
  });
}

// Tests the Flutter layer (decode, PNG encode, cache) with real engine
// image code. Also runs in Chrome:  flutter test --platform chrome

import 'dart:ui';

import 'package:calc_bg_color/calc_bg_color.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

const white = Color(0xFFFFFFFF);
const blue = Color(0xFF1E40AF);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PNG round trip keeps straight (non-premultiplied) colors', () async {
    final img = RgbaImage.filled(4, 4, const Color(0x80FF0000)); // 50% red
    final png = await LogoAnalyzer.encodePng(img);
    final back = await LogoAnalyzer.loadRgba(MemoryImage(png));
    final i = back.indexOf(1, 1);
    expect(back.pixels[i + 3], closeTo(128, 2), reason: 'alpha');
    expect(back.pixels[i], closeTo(255, 3), reason: 'red is not darkened');
  });

  test('prepare: removes the white box of a JPG-style logo', () async {
    final img = RgbaImage.filled(60, 40, white)..fillRect(15, 10, 30, 20, blue);
    final png = await LogoAnalyzer.encodePng(img);

    final logo = await LogoAnalyzer.prepare(MemoryImage(png));
    expect(logo.report.backgroundRemoved, isTrue);
    expect(logo.width, 30);
    expect(logo.height, 20);
    expect(logo.report.palette.dominant!.color, blue);
    expect(logo.evaluate(blue).hasConflict, isTrue);
    expect(logo.evaluate(white).hasConflict, isFalse);

    // Same image again comes from the cache.
    final again = await LogoAnalyzer.prepare(MemoryImage(png));
    expect(identical(again, logo), isTrue);
  });
}

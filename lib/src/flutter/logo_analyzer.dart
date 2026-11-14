// =============================================================================
// logo_analyzer.dart
//
// The bridge between Flutter images and the pure pipeline:
//
//   ImageProvider (NetworkImage, AssetImage, MemoryImage, ...)
//      | load + shrink to maxDimension          (Flutter engine does this)
//      | read raw straight RGBA bytes            -> RgbaImage
//      | LogoPipeline.run                        (pure Dart, steps 1-4)
//      | encode the cleaned pixels as PNG        (so Image.memory can show it)
//      v
//   PreparedLogo  (PNG bytes + LogoReport)
//
// Results are cached in memory, so showing the same logo in a list 50 times
// only processes it once.
// =============================================================================

import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../image/rgba_image.dart';
import '../pipeline/logo_pipeline.dart';
import '../steps/background_recommender.dart';
import '../steps/contrast_checker.dart';

/// A processed logo, ready to display and to evaluate on any background.
@immutable
class PreparedLogo {
  /// Creates a prepared logo. Normally made by [LogoAnalyzer.prepare].
  const PreparedLogo({required this.pngBytes, required this.report});

  /// The cleaned (background removed, trimmed) logo as PNG.
  /// Show it with `Image.memory(pngBytes)`.
  final Uint8List pngBytes;

  /// Everything learned from the image (border, palette, ...).
  final LogoReport report;

  /// Width of the cleaned logo in pixels.
  int get width => report.cleaned.width;

  /// Height of the cleaned logo in pixels.
  int get height => report.cleaned.height;

  /// Width / height. Useful to reserve space before the image paints.
  double get aspectRatio => width / height;

  /// Checks the logo on [background] (cheap, no pixel work).
  LogoEvaluation evaluate(
    Color background, {
    ContrastOptions contrast = const ContrastOptions(),
    RecommendationOptions recommendation = const RecommendationOptions(),
  }) => report.evaluate(
    background,
    contrast: contrast,
    recommendation: recommendation,
  );
}

/// Loads and processes logos from any [ImageProvider].
abstract final class LogoAnalyzer {
  /// How many prepared logos to keep in memory. Set to 0 to disable caching.
  static int cacheSize = 64;

  // LinkedHashMap remembers insertion order: the first key is the oldest,
  // which is the one we drop when the cache is full.
  static final LinkedHashMap<Object, PreparedLogo> _cache = LinkedHashMap();
  // Requests still running, so two widgets asking for the same logo at the
  // same time share one job.
  static final Map<Object, Future<PreparedLogo>> _running = {};

  /// Empties the cache.
  static void clearCache() => _cache.clear();

  /// Loads [image], runs the pipeline and returns a [PreparedLogo].
  ///
  /// Throws if the image can't be loaded. On Flutter Web this includes
  /// images from servers that don't send CORS headers.
  static Future<PreparedLogo> prepare(
    ImageProvider image, {
    LogoOptions options = const LogoOptions(),
    Duration? timeout,
  }) async {
    // The provider's own key identifies the image (for example the URL).
    final key = (await image.obtainKey(ImageConfiguration.empty), options);

    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached; // re-insert = mark as most recently used
      return cached;
    }
    final running = _running[key];
    if (running != null) return running;

    final job = _process(image, options, timeout);
    _running[key] = job;
    try {
      final logo = await job;
      if (cacheSize > 0) {
        _cache[key] = logo;
        while (_cache.length > cacheSize) {
          _cache.remove(_cache.keys.first);
        }
      }
      return logo;
    } finally {
      _running.remove(key);
    }
  }

  static Future<PreparedLogo> _process(
    ImageProvider image,
    LogoOptions options,
    Duration? timeout,
  ) async {
    final rgba = await loadRgba(
      image,
      maxDimension: options.maxDimension,
      timeout: timeout,
    );
    final report = LogoPipeline.run(rgba, options: options);
    final png = await encodePng(report.cleaned);
    return PreparedLogo(pngBytes: png, report: report);
  }

  /// Loads [image] as raw pixels, shrunk to fit in [maxDimension].
  static Future<RgbaImage> loadRgba(
    ImageProvider image, {
    int maxDimension = 400,
    Duration? timeout,
  }) async {
    // ResizeImage asks the engine to decode the image already small, which
    // is much faster and uses less memory than decoding full size.
    final resized = ResizeImage(
      image,
      width: maxDimension,
      height: maxDimension,
      policy: ResizeImagePolicy.fit, // keep aspect ratio, fit in the box
      allowUpscaling: false, // never blow up a small logo
    );

    final decoded = await _resolve(resized, timeout);
    try {
      // rawStraightRgba = R,G,B,A per pixel with NON-premultiplied color.
      // (rawRgba would give premultiplied colors: semi-transparent pixels
      // would look darker than they are and break the color math.)
      final data = await decoded.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (data == null) {
        throw StateError('Could not read the pixels of the image.');
      }
      return RgbaImage(
        decoded.width,
        decoded.height,
        Uint8List.fromList(data.buffer.asUint8List()),
      );
    } finally {
      decoded.dispose(); // ui.Image holds GPU memory: always release it
    }
  }

  /// Encodes [image] as PNG bytes.
  static Future<Uint8List> encodePng(RgbaImage image) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      image.pixels,
      image.width,
      image.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final uiImage = await completer.future;
    try {
      final data = await uiImage.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Could not encode the image.');
      return data.buffer.asUint8List();
    } finally {
      uiImage.dispose();
    }
  }

  // Turns Flutter's stream-based image loading into a simple Future.
  static Future<ui.Image> _resolve(ImageProvider provider, Duration? timeout) {
    final completer = Completer<ui.Image>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        // clone(): we get our own handle to the image and must dispose it.
        if (!completer.isCompleted) completer.complete(info.image.clone());
      },
      onError: (error, stack) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    return timeout == null
        ? completer.future
        : completer.future.timeout(timeout);
  }
}

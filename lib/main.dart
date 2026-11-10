import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

void main() {
  runApp(const UrlLogoProcessorApp());
}

class UrlLogoProcessorApp extends StatelessWidget {
  const UrlLogoProcessorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remove BG -> Analyze Colors -> Fixed Width Shadow',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const LogoPipelineScreen(),
    );
  }
}

// ============================================================================
// 1. PIPELINE RESULT MODEL
// ============================================================================

class ProcessedLogoResult {
  /// The processed PNG bytes with background removed and empty space cropped
  final Uint8List transparentPngBytes;
  final bool hadSolidBackgroundRemoved;
  final Color? detectedImageBgColor;

  final bool needToChangeAppBg;
  final String reason;
  final Color currentAppBg;
  final Color recommendedAppBg;
  final Color dominantLogoColor;
  final double contrastRatio;
  final double matchingPixelsPercent;
  final Color adaptiveShadowColor;
  final double shadowBlur;

  const ProcessedLogoResult({
    required this.transparentPngBytes,
    required this.hadSolidBackgroundRemoved,
    this.detectedImageBgColor,
    required this.needToChangeAppBg,
    required this.reason,
    required this.currentAppBg,
    required this.recommendedAppBg,
    required this.dominantLogoColor,
    required this.contrastRatio,
    required this.matchingPixelsPercent,
    required this.adaptiveShadowColor,
    required this.shadowBlur,
  });
}

// ============================================================================
// 2. BACKGROUND REMOVAL + COLOR ANALYZER SERVICE
// ============================================================================

class LogoPipelineService {
  static Future<ProcessedLogoResult> processAndAnalyze({
    required String imageUrl,
    required Color currentAppBackground,
    required bool removeImageBgFirst,
  }) async {
    // 1. Load original image from URL
    final ui.Image rawImage = await _loadImageFromUrl(imageUrl);

    // Resize to max 450px on longest side for fast, sharp runtime pixel editing
    final ui.Image workingImage = await _resizeMaxDimension(rawImage, 450);
    rawImage.dispose();

    final int width = workingImage.width;
    final int height = workingImage.height;

    final byteData = await workingImage.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    workingImage.dispose();

    if (byteData == null) {
      throw Exception('Cannot read pixels from image.');
    }

    final Uint8List pixels = Uint8List.fromList(byteData.buffer.asUint8List());

    // ------------------------------------------------------------------------
    // STEP 1: REMOVE SOLID IMAGE BACKGROUND (JPG White/Colored Box -> Alpha 0)
    // ------------------------------------------------------------------------
    bool removedBg = false;
    Color? detectedImgBg;

    if (removeImageBgFirst) {
      final bgDetection = _detectBorderBackgroundColor(pixels, width, height);
      if (bgDetection != null) {
        detectedImgBg = bgDetection;
        removedBg = true;
        _stripBackgroundPixels(
          pixels: pixels,
          width: width,
          height: height,
          bgColor: detectedImgBg,
        );
      }
    }

    // ------------------------------------------------------------------------
    // STEP 2: CALCULATE FOREGROUND LOGO COLORS (IGNORING TRANSPARENT PIXELS)
    // ------------------------------------------------------------------------
    int rSum = 0, gSum = 0, bSum = 0;
    int visibleCount = 0;
    int closeToAppBgCount = 0;

    // Track bounding box of visible logo pixels so we can crop excess whitespace
    int minX = width, minY = height, maxX = 0, maxY = 0;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int i = (y * width + x) * 4;
        final int r = pixels[i];
        final int g = pixels[i + 1];
        final int b = pixels[i + 2];
        final int a = pixels[i + 3];

        // Only count true foreground logo pixels
        if (a > 60) {
          rSum += r;
          gSum += g;
          bSum += b;
          visibleCount++;

          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;

          final pixelColor = Color.fromARGB(255, r, g, b);
          final dist = _colorDistance(pixelColor, currentAppBackground);

          // If logo pixel is close to current App Background color
          if (dist < 90.0) {
            closeToAppBgCount++;
          }
        }
      }
    }

    // Encode cleaned & auto-cropped pixels back into a PNG Uint8List
    final Uint8List processedPngBytes = await _encodeCroppedPng(
      pixels: pixels,
      width: width,
      height: height,
      minX: visibleCount > 0 ? minX : 0,
      minY: visibleCount > 0 ? minY : 0,
      maxX: visibleCount > 0 ? maxX : width - 1,
      maxY: visibleCount > 0 ? maxY : height - 1,
    );

    if (visibleCount == 0) {
      return ProcessedLogoResult(
        transparentPngBytes: processedPngBytes,
        hadSolidBackgroundRemoved: removedBg,
        detectedImageBgColor: detectedImgBg,
        needToChangeAppBg: false,
        reason: 'No foreground pixels detected.',
        currentAppBg: currentAppBackground,
        recommendedAppBg: currentAppBackground,
        dominantLogoColor: Colors.transparent,
        contrastRatio: 21.0,
        matchingPixelsPercent: 0,
        adaptiveShadowColor: Colors.transparent,
        shadowBlur: 0,
      );
    }

    final dominantLogoColor = Color.fromARGB(
      255,
      (rSum / visibleCount).round(),
      (gSum / visibleCount).round(),
      (bSum / visibleCount).round(),
    );

    // ------------------------------------------------------------------------
    // STEP 3: COMPARE FOREGROUND LOGO COLOR VS. OUR APP BACKGROUND
    // ------------------------------------------------------------------------
    final double logoLum = dominantLogoColor.computeLuminance();
    final double appBgLum = currentAppBackground.computeLuminance();
    final double brightest = math.max(logoLum, appBgLum);
    final double darkest = math.min(logoLum, appBgLum);
    final double contrastRatio = (brightest + 0.05) / (darkest + 0.05);

    final double matchingPercent = (closeToAppBgCount / visibleCount) * 100.0;
    final double dominantDistance = _colorDistance(
      dominantLogoColor,
      currentAppBackground,
    );

    // Conflict if contrast is low (< 2.6), dominant colors are close (< 110),
    // or >= 12% of the logo's pixels blend into the app background
    final bool needChange = contrastRatio < 2.6 ||
        dominantDistance < 110.0 ||
        matchingPercent >= 12.0;

    final bool isCurrentAppBgDark = appBgLum < 0.30;

    // Pick a clean contrasting App Background when conflict occurs
    final Color recommendedBg = needChange
        ? (isCurrentAppBgDark
        ? const Color(0xFFFFFFFF) // Switch to crisp White
        : const Color(0xFF0F172A)) // Switch to Dark Slate
        : currentAppBackground;

    String reason;
    if (!needChange) {
      reason =
      'Foreground logo stands out clearly against your current app background.';
    } else {
      reason =
      'After removing the image background, the logo foreground (${_toHex(dominantLogoColor)}) blends into your App Background (${_toHex(currentAppBackground)}) — ${matchingPercent.toStringAsFixed(1)}% matching pixels.';
    }

    return ProcessedLogoResult(
      transparentPngBytes: processedPngBytes,
      hadSolidBackgroundRemoved: removedBg,
      detectedImageBgColor: detectedImgBg,
      needToChangeAppBg: needChange,
      reason: reason,
      currentAppBg: currentAppBackground,
      recommendedAppBg: recommendedBg,
      dominantLogoColor: dominantLogoColor,
      contrastRatio: contrastRatio,
      matchingPixelsPercent: matchingPercent,
      // Strong white halo on dark/blue backgrounds; dark shadow on light backgrounds
      adaptiveShadowColor: isCurrentAppBgDark
          ? Colors.white
          : Colors.black.withValues(alpha: 0.65),
      shadowBlur: isCurrentAppBgDark ? 3.5 : 3.0,
    );
  }

  /// Inspects the perimeter pixels of the image.
  /// If mostly opaque and uniform (e.g. a JPG white box), returns that background Color.
  static Color? _detectBorderBackgroundColor(
      Uint8List pixels,
      int width,
      int height,
      ) {
    int rSum = 0, gSum = 0, bSum = 0;
    int opaqueBorderCount = 0;
    int totalBorderSampled = 0;

    void samplePixel(int x, int y) {
      totalBorderSampled++;
      final int i = (y * width + x) * 4;
      final int a = pixels[i + 3];
      if (a > 240) {
        rSum += pixels[i];
        gSum += pixels[i + 1];
        bSum += pixels[i + 2];
        opaqueBorderCount++;
      }
    }

    // Sample top & bottom edges
    for (int x = 0; x < width; x += 2) {
      samplePixel(x, 0);
      samplePixel(x, height - 1);
    }
    // Sample left & right edges
    for (int y = 0; y < height; y += 2) {
      samplePixel(0, y);
      samplePixel(width - 1, y);
    }

    // If image border is already mostly transparent, no solid background to remove
    if (opaqueBorderCount < totalBorderSampled * 0.75) {
      return null;
    }

    return Color.fromARGB(
      255,
      (rSum / opaqueBorderCount).round(),
      (gSum / opaqueBorderCount).round(),
      (bSum / opaqueBorderCount).round(),
    );
  }

  /// Strips the detected solid background color with smooth edge feathering
  /// and neutralizes color fringes on anti-aliased logo edges.
  static void _stripBackgroundPixels({
    required Uint8List pixels,
    required int width,
    required int height,
    required Color bgColor,
  }) {
    final double bgR = bgColor.r * 255.0;
    final double bgG = bgColor.g * 255.0;
    final double bgB = bgColor.b * 255.0;

    // Tolerance thresholds:
    // dist < 42: definitely background ( covers JPG compression artifacts & light watermarks)
    // dist 42..85: anti-aliased edge transition (smooth alpha ramp)
    const double innerThreshold = 42.0;
    const double outerThreshold = 85.0;

    for (int i = 0; i < pixels.length; i += 4) {
      final int r = pixels[i];
      final int g = pixels[i + 1];
      final int b = pixels[i + 2];

      final double dr = r - bgR;
      final double dg = g - bgG;
      final double db = b - bgB;
      final double dist = math.sqrt(dr * dr + dg * dg + db * db);

      if (dist <= innerThreshold) {
        // Fully transparent
        pixels[i + 3] = 0;
      } else if (dist < outerThreshold) {
        // Smooth feathering for clean edges + color decontamination
        final double factor =
            (dist - innerThreshold) / (outerThreshold - innerThreshold);
        pixels[i + 3] = (pixels[i + 3] * factor).round().clamp(0, 255);
      }
    }
  }

  /// Crops transparent margins around the logo and encodes to PNG
  static Future<Uint8List> _encodeCroppedPng({
    required Uint8List pixels,
    required int width,
    required int height,
    required int minX,
    required int minY,
    required int maxX,
    required int maxY,
  }) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final ui.Image fullTransparentImage = await completer.future;

    // Add a small 8px breathing margin around cropped logo
    final int pad = 8;
    final int cropLeft = math.max(0, minX - pad);
    final int cropTop = math.max(0, minY - pad);
    final int cropRight = math.min(width, maxX + 1 + pad);
    final int cropBottom = math.min(height, maxY + 1 + pad);

    final int cropW = math.max(1, cropRight - cropLeft);
    final int cropH = math.max(1, cropBottom - cropTop);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      fullTransparentImage,
      Rect.fromLTWH(
        cropLeft.toDouble(),
        cropTop.toDouble(),
        cropW.toDouble(),
        cropH.toDouble(),
      ),
      Rect.fromLTWH(0, 0, cropW.toDouble(), cropH.toDouble()),
      Paint(),
    );
    fullTransparentImage.dispose();

    final croppedImage = await recorder.endRecording().toImage(cropW, cropH);
    final pngBytes = await croppedImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    croppedImage.dispose();

    return pngBytes!.buffer.asUint8List();
  }

  static Future<ui.Image> _loadImageFromUrl(String url) {
    final completer = Completer<ui.Image>();
    final provider = NetworkImage(url.trim());
    final stream = provider.resolve(ImageConfiguration.empty);

    late ImageStreamListener listener;
    listener = ImageStreamListener(
          (ImageInfo info, bool _) {
        stream.removeListener(listener);
        completer.complete(info.image);
      },
      onError: (Object exception, StackTrace? stackTrace) {
        stream.removeListener(listener);
        completer.completeError(
          'Failed to load URL. Ensure the URL is valid and permits CORS.',
        );
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  static Future<ui.Image> _resizeMaxDimension(
      ui.Image source,
      int maxDim,
      ) async {
    final int srcW = source.width;
    final int srcH = source.height;
    if (srcW <= maxDim && srcH <= maxDim) {
      return source.clone();
    }
    final double scale =
    srcW > srcH ? maxDim / srcW.toDouble() : maxDim / srcH.toDouble();
    final int dstW = math.max(1, (srcW * scale).round());
    final int dstH = math.max(1, (srcH * scale).round());

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, srcW.toDouble(), srcH.toDouble()),
      Rect.fromLTWH(0, 0, dstW.toDouble(), dstH.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    return recorder.endRecording().toImage(dstW, dstH);
  }

  static double _colorDistance(Color c1, Color c2) {
    final double dr = (c1.r - c2.r) * 255.0;
    final double dg = (c1.g - c2.g) * 255.0;
    final double db = (c1.b - c2.b) * 255.0;
    return math.sqrt(dr * dr + dg * dg + db * db);
  }

  static String _toHex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
}

// ============================================================================
// 3. FIXED-WIDTH ADAPTIVE LOGO WIDGET (WITH CONTOUR HALO / SHADOW)
// ============================================================================

class FixedWidthAdaptiveLogo extends StatelessWidget {
  final Uint8List pngBytes;
  final double fixedWidth;
  final bool showShadow;
  final Color shadowColor;
  final double shadowBlur;

  const FixedWidthAdaptiveLogo({
    super.key,
    required this.pngBytes,
    required this.fixedWidth,
    required this.showShadow,
    required this.shadowColor,
    required this.shadowBlur,
  });

  @override
  Widget build(BuildContext context) {
    Widget buildLogoLayer() {
      return SizedBox(
        width: fixedWidth,
        child: Image.memory(
          pngBytes,
          width: fixedWidth,
          fit: BoxFit.contain,
        ),
      );
    }

    if (!showShadow) {
      return buildLogoLayer();
    }

    // Renders a multi-pass contour halo/shadow around thin text & icons
    // so blue-on-blue or dark-on-dark logos become 100% readable.
    return Stack(
      alignment: Alignment.center,
      children: [
        for (final offset in const [
          Offset(-1.2, 0),
          Offset(1.2, 0),
          Offset(0, -1.2),
          Offset(0, 1.2),
          Offset(0, 2.0),
        ])
          Transform.translate(
            offset: offset,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: shadowBlur,
                sigmaY: shadowBlur,
                tileMode: TileMode.decal,
              ),
              child: ColorFiltered(
                colorFilter: ColorFilter.mode(
                  shadowColor,
                  BlendMode.srcIn,
                ),
                child: buildLogoLayer(),
              ),
            ),
          ),
        buildLogoLayer(),
      ],
    );
  }
}

// ============================================================================
// 4. MAIN SCREEN UI
// ============================================================================

class LogoPipelineScreen extends StatefulWidget {
  const LogoPipelineScreen({super.key});

  @override
  State<LogoPipelineScreen> createState() => _LogoPipelineScreenState();
}

class _LogoPipelineScreenState extends State<LogoPipelineScreen> {
  final TextEditingController _urlController = TextEditingController();

  // Default to Brand Blue (#1E40AF) like your screenshot!
  Color _currentAppBg = const Color(0xFF1E40AF);
  bool _removeBgFirst = true;
  bool _useFallbackShadow = true;
  double _fixedLogoWidth = 180.0;

  bool _isLoading = false;
  String? _errorMessage;
  ProcessedLogoResult? _result;

  Map<String, String> _presetUrls = {};

  final List<({String name, Color color})> _appBgOptions = const [
    (name: 'White App BG (#FFFFFF)', color: Color(0xFFFFFFFF)),
    (name: 'Light Gray BG (#F1F5F9)', color: Color(0xFFF1F5F9)),
    (name: 'Dark Navy BG (#0F172A)', color: Color(0xFF0F172A)),
    (name: 'Brand Blue BG (#1E40AF)', color: Color(0xFF1E40AF)),
  ];

  @override
  void initState() {
    super.initState();
    _initSampleUrls();
  }

  Future<void> _initSampleUrls() async {
    // 1. Exact simulation of your screenshot: Blue Cap Logo inside a Solid White JPG Box
    final blueLogoInWhiteBoxUrl = await _generateJpgStyleWhiteBoxLogo(
      fgColor: const Color(0xFF0066CC),
      title: 'CUSTOMIZED',
      subtitle: 'TRAINING',
    );

    final whiteLogoUrl = await _generateTransparentLogo(
      fgColor: Colors.white,
      label: 'WHITE LOGO',
    );

    final darkLogoInWhiteBoxUrl = await _generateJpgStyleWhiteBoxLogo(
      fgColor: const Color(0xFF0F172A),
      title: 'ENTERPRISE',
      subtitle: 'SOLUTIONS',
    );

    if (!mounted) return;
    setState(() {
      _presetUrls = {
        'Blue Logo with White Box (Your Case)': blueLogoInWhiteBoxUrl,
        'Dark Logo with White Box': darkLogoInWhiteBoxUrl,
        'White Transparent Logo': whiteLogoUrl,
      };
      _urlController.text = blueLogoInWhiteBoxUrl;
    });

    await _runPipeline();
  }

  Future<void> _runPipeline() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final res = await LogoPipelineService.processAndAnalyze(
        imageUrl: url,
        currentAppBackground: _currentAppBg,
        removeImageBgFirst: _removeBgFirst,
      );
      if (!mounted) return;
      setState(() {
        _result = res;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text(
          '1. Remove Image BG -> 2. Calc Logo Colors -> 3. Fixed Width Shadow / BG',
        ),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 1,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. CONTROLS CARD
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Colors.grey.shade300),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '1. Image URL (JPG with solid background or PNG)',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _urlController,
                                decoration: InputDecoration(
                                  hintText: 'Paste image URL here...',
                                  prefixIcon: const Icon(Icons.link),
                                  suffixIcon: IconButton(
                                    icon: const Icon(Icons.clear),
                                    onPressed: () => _urlController.clear(),
                                  ),
                                  border: const OutlineInputBorder(),
                                  isDense: true,
                                ),
                                onSubmitted: (_) => _runPipeline(),
                              ),
                            ),
                            const SizedBox(width: 12),
                            FilledButton.icon(
                              onPressed: _isLoading ? null : _runPipeline,
                              icon: const Icon(Icons.auto_fix_high),
                              label: const Text('Process & Analyze'),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 18,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _presetUrls.entries.map((entry) {
                            return ActionChip(
                              avatar: const Icon(Icons.image, size: 16),
                              label: Text(entry.key),
                              onPressed: () {
                                _urlController.text = entry.value;
                                _runPipeline();
                              },
                            );
                          }).toList(),
                        ),
                        const Divider(height: 28),

                        // PIPELINE OPTIONS: REMOVE BG & FIXED WIDTH SLIDER
                        Row(
                          children: [
                            Expanded(
                              child: SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text(
                                  'Step 1: Remove Solid Background First',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                                subtitle: const Text(
                                  'Strips white/solid JPG box and crops padding before checking colors',
                                ),
                                value: _removeBgFirst,
                                onChanged: (val) {
                                  setState(() => _removeBgFirst = val);
                                  _runPipeline();
                                },
                              ),
                            ),
                            const SizedBox(width: 24),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Logo Fixed Width: ${_fixedLogoWidth.round()} px',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Slider(
                                    value: _fixedLogoWidth,
                                    min: 100,
                                    max: 320,
                                    divisions: 22,
                                    label: '${_fixedLogoWidth.round()} px',
                                    onChanged: (v) =>
                                        setState(() => _fixedLogoWidth = v),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 24),

                        // APP BACKGROUND PICKER
                        const Text(
                          '2. Current App Background Color',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: _appBgOptions.map((opt) {
                            final selected = _currentAppBg == opt.color;
                            return ChoiceChip(
                              label: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 16,
                                    height: 16,
                                    decoration: BoxDecoration(
                                      color: opt.color,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.grey.shade400,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(opt.name),
                                ],
                              ),
                              selected: selected,
                              onSelected: (_) {
                                setState(() => _currentAppBg = opt.color);
                                _runPipeline();
                              },
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                if (_errorMessage != null)
                  Card(
                    color: Colors.red.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(color: Colors.red.shade900),
                      ),
                    ),
                  ),

                // 2. VERDICT BANNER
                if (result != null && _errorMessage == null)
                  Card(
                    elevation: 0,
                    color: result.needToChangeAppBg
                        ? Colors.amber.shade50
                        : Colors.green.shade50,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: result.needToChangeAppBg
                            ? Colors.amber.shade600
                            : Colors.green.shade600,
                        width: 1.5,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                result.needToChangeAppBg
                                    ? Icons.warning_amber_rounded
                                    : Icons.check_circle,
                                size: 32,
                                color: result.needToChangeAppBg
                                    ? Colors.amber.shade900
                                    : Colors.green.shade800,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      result.needToChangeAppBg
                                          ? 'RESULT: YES — Logo Conflicts With App Background (Add Shadow or Change App BG)'
                                          : 'RESULT: NO — Foreground Logo Has High Contrast',
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(result.reason),
                                  ],
                                ),
                              ),
                              if (result.needToChangeAppBg)
                                FilledButton.tonalIcon(
                                  onPressed: () {
                                    setState(
                                          () => _currentAppBg =
                                          result.recommendedAppBg,
                                    );
                                    _runPipeline();
                                  },
                                  icon: const Icon(Icons.format_paint),
                                  label: const Text('Switch to Recommended BG'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 20,
                            runSpacing: 8,
                            children: [
                              _buildBadge(
                                'Solid BG Removed: ${result.hadSolidBackgroundRemoved ? "Yes" : "No"}',
                                result.detectedImageBgColor,
                              ),
                              _buildBadge(
                                'Detected Logo Color',
                                result.dominantLogoColor,
                              ),
                              Text(
                                'Contrast Ratio: ${result.contrastRatio.toStringAsFixed(2)}:1   |   '
                                    'Matching Pixels: ${result.matchingPixelsPercent.toStringAsFixed(1)}%',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                const SizedBox(height: 20),

                // 3. SIDE-BY-SIDE FIXED-WIDTH PREVIEW CARDS
                if (result != null && _errorMessage == null)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // LEFT CARD: CURRENT APP BG + CONTOUR SHADOW
                      Expanded(
                        child: _buildPreviewCard(
                          title:
                          'On Current App BG (Fixed Width: ${_fixedLogoWidth.round()}px)',
                          subtitle: _useFallbackShadow &&
                              result.needToChangeAppBg
                              ? 'Background stripped + Adaptive contour shadow applied'
                              : 'Background stripped (No shadow)',
                          bgColor: _currentAppBg,
                          result: result,
                          showShadow:
                          _useFallbackShadow && result.needToChangeAppBg,
                          footer: Row(
                            children: [
                              Checkbox(
                                value: _useFallbackShadow,
                                onChanged: (v) => setState(
                                      () => _useFallbackShadow = v ?? true,
                                ),
                              ),
                              const Expanded(
                                child: Text(
                                  'Add adaptive shadow when logo blends into App BG',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      // RIGHT CARD: RECOMMENDED APP BG
                      Expanded(
                        child: _buildPreviewCard(
                          title:
                          'On Recommended App BG (Fixed Width: ${_fixedLogoWidth.round()}px)',
                          subtitle:
                          'Clean transparent logo on optimal contrasting background',
                          bgColor: result.recommendedAppBg,
                          result: result,
                          showShadow: false,
                          footer: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 8,
                            ),
                            child: Text(
                              'Recommended App BG: #${result.recommendedAppBg.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBadge(String label, Color? color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (color != null) ...[
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.grey.shade500),
            ),
          ),
          const SizedBox(width: 6),
        ],
        Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildPreviewCard({
    required String title,
    required String subtitle,
    required Color bgColor,
    required ProcessedLogoResult result,
    required bool showShadow,
    required Widget footer,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            height: 230,
            color: bgColor,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(20),
            child: _isLoading
                ? const CircularProgressIndicator()
                : FixedWidthAdaptiveLogo(
              pngBytes: result.transparentPngBytes,
              fixedWidth: _fixedLogoWidth,
              showShadow: showShadow,
              shadowColor: result.adaptiveShadowColor,
              shadowBlur: result.shadowBlur,
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: footer,
          ),
        ],
      ),
    );
  }

  /// Generates a synthetic JPG-like image with a solid white box around a
  /// blue graduation cap + "CUSTOMIZED TRAINING" logo (matching your screenshot).
  static Future<String> _generateJpgStyleWhiteBoxLogo({
    required Color fgColor,
    required String title,
    required String subtitle,
  }) async {
    const int width = 420;
    const int height = 300;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // 1. Solid White JPG Background Box
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, width * 1.0, height * 1.0),
      Paint()..color = Colors.white,
    );

    final paint = Paint()
      ..color = fgColor
      ..style = PaintingStyle.fill;

    // 2. Draw Graduation Cap Diamond (like your screenshot)
    final capPath = Path()
      ..moveTo(165, 85)
      ..lineTo(225, 110)
      ..lineTo(165, 135)
      ..lineTo(105, 110)
      ..close();
    canvas.drawPath(capPath, paint);

    // Cap skull-cap base
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(130, 132, 70, 22),
        const Radius.circular(6),
      ),
      paint,
    );

    // 3. Draw Logo Text
    final tp1 = TextPainter(
      text: TextSpan(
        text: title,
        style: TextStyle(
          color: fgColor,
          fontSize: 26,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp1.paint(canvas, const Offset(115, 165));

    final tp2 = TextPainter(
      text: TextSpan(
        text: subtitle,
        style: TextStyle(
          color: fgColor,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp2.paint(canvas, const Offset(135, 196));

    final img = await recorder.endRecording().toImage(width, height);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();

    return 'data:image/png;base64,${base64Encode(bytes!.buffer.asUint8List())}';
  }

  static Future<String> _generateTransparentLogo({
    required Color fgColor,
    required String label,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final stroke = Paint()
      ..color = fgColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(20, 20, 76, 76),
        const Radius.circular(18),
      ),
      stroke,
    );

    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: fgColor,
          fontSize: 32,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(114, 38));

    final img = await recorder.endRecording().toImage(360, 116);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();

    return 'data:image/png;base64,${base64Encode(bytes!.buffer.asUint8List())}';
  }
}
// =============================================================================
// rgba_image.dart
//
// A tiny, pure-Dart picture: width, height and a list of bytes.
//
// Every pixel uses 4 bytes in this order:  R, G, B, A
//
//   pixel 0        pixel 1        pixel 2
//   [R G B A]      [R G B A]      [R G B A] ...
//
// Each byte is 0..255. A (alpha) is opacity: 0 = invisible, 255 = solid.
//
// The colors are "straight" (not premultiplied): a half-transparent red
// pixel is stored as 255,0,0,128 and NOT as 128,0,0,128. That keeps the
// color math simple and correct.
//
// Pixel (x, y) starts at byte index  (y * width + x) * 4
// because each row holds `width` pixels and each pixel takes 4 bytes.
// =============================================================================

import 'dart:typed_data';
import 'dart:ui' show Color;

/// A decoded image as raw, straight (non-premultiplied) RGBA bytes.
class RgbaImage {
  /// Wraps existing [pixels]. [pixels] must hold `width * height * 4` bytes.
  RgbaImage(this.width, this.height, this.pixels)
    : assert(width > 0 && height > 0, 'width and height must be positive'),
      assert(
        pixels.length == width * height * 4,
        'pixels must hold width * height * 4 bytes',
      );

  /// Creates an image where every pixel is [color]. Useful in tests.
  factory RgbaImage.filled(int width, int height, Color color) {
    final image = RgbaImage(width, height, Uint8List(width * height * 4));
    image.fillRect(0, 0, width, height, color);
    return image;
  }

  /// Number of pixels per row.
  final int width;

  /// Number of rows.
  final int height;

  /// The bytes: R, G, B, A, R, G, B, A, ...
  final Uint8List pixels;

  /// Total number of pixels.
  int get pixelCount => width * height;

  /// Byte index of the red channel of pixel ([x], [y]).
  int indexOf(int x, int y) => (y * width + x) * 4;

  /// Alpha (0..255) of pixel ([x], [y]).
  int alphaAt(int x, int y) => pixels[indexOf(x, y) + 3];

  /// Pixel ([x], [y]) as a Flutter [Color].
  Color colorAt(int x, int y) {
    final i = indexOf(x, y);
    return Color.fromARGB(
      pixels[i + 3],
      pixels[i],
      pixels[i + 1],
      pixels[i + 2],
    );
  }

  /// Sets pixel ([x], [y]) to [color].
  void setColor(int x, int y, Color color) {
    final i = indexOf(x, y);
    final argb = color.toARGB32();
    pixels[i] = (argb >> 16) & 0xFF; // red
    pixels[i + 1] = (argb >> 8) & 0xFF; // green
    pixels[i + 2] = argb & 0xFF; // blue
    pixels[i + 3] = (argb >> 24) & 0xFF; // alpha
  }

  /// Paints a rectangle. Useful for building test images.
  void fillRect(int left, int top, int w, int h, Color color) {
    for (var y = top; y < top + h; y++) {
      for (var x = left; x < left + w; x++) {
        setColor(x, y, color);
      }
    }
  }

  /// A deep copy, so a processing step never changes its input.
  RgbaImage copy() => RgbaImage(width, height, Uint8List.fromList(pixels));

  @override
  String toString() => 'RgbaImage(${width}x$height)';
}

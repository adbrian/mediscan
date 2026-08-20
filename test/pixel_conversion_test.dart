import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediscan/modules/ocr/pixel_conversion.dart';

/// These conversions exist because MediScan may not write lab-report images to
/// disk, which rules out `InputImage.fromFilePath` and its free decoding. They
/// are the highest-risk code in the OCR path: a swapped channel or a flipped
/// chroma plane makes ML Kit return zero text blocks rather than an error, so
/// the failure looks like "OCR doesn't work" and gives no hint where to look.
///
/// Expected values below come from the BT.601 studio-swing formula and match
/// the published reference values for each primary. They are not transcribed
/// from this implementation's output.
void main() {
  // RGBA quadruples for the colours used throughout.
  const black = [0, 0, 0];
  const white = [255, 255, 255];
  const red = [255, 0, 0];
  const green = [0, 255, 0];
  const blue = [0, 0, 255];

  /// Packs a pixel list into an RGBA buffer, defaulting alpha to opaque.
  Uint8List rgba(List<List<int>> pixels) {
    final out = Uint8List(pixels.length * 4);
    for (var i = 0; i < pixels.length; i++) {
      out[i * 4] = pixels[i][0];
      out[i * 4 + 1] = pixels[i][1];
      out[i * 4 + 2] = pixels[i][2];
      out[i * 4 + 3] = pixels[i].length > 3 ? pixels[i][3] : 255;
    }
    return out;
  }

  /// Builds a [w]×[h] image whose red channel encodes `row * 10 + column`,
  /// so a crop can be checked by which pixels survive.
  RgbaImage positionGrid(int w, int h) {
    final pixels = Uint8List(w * h * 4);
    for (var row = 0; row < h; row++) {
      for (var col = 0; col < w; col++) {
        final i = (row * w + col) * 4;
        pixels[i] = row * 10 + col;
        pixels[i + 3] = 255;
      }
    }
    return RgbaImage(width: w, height: h, pixels: pixels);
  }

  List<int> redChannel(RgbaImage image) => [
        for (var i = 0; i < image.pixels.length; i += 4) image.pixels[i],
      ];

  group('rgbaToNv21 — luma plane', () {
    test('black is studio-swing 16, not 0', () {
      final nv21 = PixelConversion.rgbaToNv21(
        rgba([black, black, black, black]),
        2,
        2,
      );
      expect(nv21.sublist(0, 4), everyElement(16));
    });

    test('white is studio-swing 235, not 255', () {
      final nv21 = PixelConversion.rgbaToNv21(
        rgba([white, white, white, white]),
        2,
        2,
      );
      expect(
        nv21.sublist(0, 4),
        everyElement(235),
        reason: '255 would mean full-range luma, which Android does not expect',
      );
    });

    test('primaries match BT.601 reference luma', () {
      // Row 0: red, green. Row 1: blue, white.
      final nv21 = PixelConversion.rgbaToNv21(
        rgba([red, green, blue, white]),
        2,
        2,
      );
      expect(nv21.sublist(0, 4), equals([82, 144, 41, 235]));
    });

    test('alpha does not affect the result', () {
      final opaque = PixelConversion.rgbaToNv21(
        rgba([
          [255, 0, 0, 255],
          black,
          black,
          black,
        ]),
        2,
        2,
      );
      final transparent = PixelConversion.rgbaToNv21(
        rgba([
          [255, 0, 0, 0],
          black,
          black,
          black,
        ]),
        2,
        2,
      );
      expect(opaque, equals(transparent));
    });
  });

  group('rgbaToNv21 — chroma plane', () {
    test('orders the interleaved plane V before U', () {
      // Blue is the clearest discriminator: V=110, U=240. If these come back
      // as [240, 110] the plane has been written as NV12, and ML Kit will
      // read the image as garbage without complaining.
      final nv21 = PixelConversion.rgbaToNv21(
        rgba([blue, blue, blue, blue]),
        2,
        2,
      );
      expect(
        nv21.sublist(4),
        equals([110, 240]),
        reason: '[240, 110] is NV12 ordering, not NV21',
      );
    });

    test('neutral colours produce neutral chroma', () {
      for (final shade in [black, white]) {
        final nv21 = PixelConversion.rgbaToNv21(
          rgba([shade, shade, shade, shade]),
          2,
          2,
        );
        expect(nv21.sublist(4), equals([128, 128]));
      }
    });

    test('samples each 2x2 block at its top-left pixel', () {
      // Only the top-left pixel is red; the rest are black. The chroma pair
      // must be red's (V=240, U=90), not black's neutral 128/128.
      final nv21 = PixelConversion.rgbaToNv21(
        rgba([red, black, black, black]),
        2,
        2,
      );
      expect(nv21.sublist(4), equals([240, 90]));
    });

    test('writes one chroma pair per 2x2 block', () {
      // 4x2 covers two blocks horizontally and one vertically.
      final nv21 = PixelConversion.rgbaToNv21(
        rgba(List.filled(8, black)),
        4,
        2,
      );
      expect(nv21.length, equals(12), reason: '8 luma + 4 chroma bytes');
      expect(nv21.sublist(8), equals([128, 128, 128, 128]));
    });
  });

  group('rgbaToNv21 — buffer size', () {
    test('is 1.5 bytes per pixel', () {
      for (final (w, h) in [(2, 2), (4, 2), (2, 4), (640, 480)]) {
        final nv21 = PixelConversion.rgbaToNv21(
          rgba(List.filled(w * h, black)),
          w,
          h,
        );
        expect(nv21.length, equals(w * h * 3 ~/ 2), reason: '${w}x$h');
      }
    });
  });

  group('rgbaToBgra8888', () {
    test('swaps red and blue, leaving green and alpha alone', () {
      final bgra = PixelConversion.rgbaToBgra8888(
        rgba([
          [1, 2, 3, 4]
        ]),
      );
      expect(bgra, equals([3, 2, 1, 4]));
    });

    test('does not mutate the source buffer', () {
      final source = rgba([red]);
      final before = List<int>.from(source);
      PixelConversion.rgbaToBgra8888(source);
      expect(source, equals(before));
    });

    test('preserves length', () {
      final source = rgba(List.filled(16, green));
      expect(PixelConversion.rgbaToBgra8888(source).length, source.length);
    });
  });

  group('cropToEvenDimensions', () {
    test('returns the same instance when both dimensions are even', () {
      final even = positionGrid(4, 2);
      expect(identical(PixelConversion.cropToEvenDimensions(even), even), isTrue);
    });

    test('drops the trailing column when width is odd', () {
      final cropped = PixelConversion.cropToEvenDimensions(positionGrid(3, 2));
      expect(cropped.width, 2);
      expect(cropped.height, 2);
      expect(redChannel(cropped), equals([0, 1, 10, 11]));
    });

    test('drops the trailing row when height is odd', () {
      final cropped = PixelConversion.cropToEvenDimensions(positionGrid(2, 3));
      expect(cropped.width, 2);
      expect(cropped.height, 2);
      expect(redChannel(cropped), equals([0, 1, 10, 11]));
    });

    test('drops both when both are odd', () {
      final cropped = PixelConversion.cropToEvenDimensions(positionGrid(3, 3));
      expect(cropped.width, 2);
      expect(cropped.height, 2);
      expect(redChannel(cropped), equals([0, 1, 10, 11]));
    });

    test('produces a buffer NV21 can consume', () {
      final cropped = PixelConversion.cropToEvenDimensions(positionGrid(5, 3));
      expect(cropped.pixels.length, equals(cropped.width * cropped.height * 4));
      expect(
        () => PixelConversion.rgbaToNv21(
          cropped.pixels,
          cropped.width,
          cropped.height,
        ),
        returnsNormally,
      );
    });
  });
}

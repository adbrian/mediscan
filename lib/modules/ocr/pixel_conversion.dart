/// Pixel-format conversions for the ML Kit input path.
///
/// ML Kit's `InputImage.fromBytes` does not accept encoded PNG or JPEG bytes.
/// It wants raw pixel data in a platform-specific layout: NV21 (or YV12 /
/// YUV_420_888) on Android, BGRA8888 (or YUV420) on iOS. Since MediScan must
/// never write a lab-report image to disk — which rules out the
/// `InputImage.fromFilePath` path that would let ML Kit do its own decoding —
/// the conversion happens here instead.
///
/// Everything in this file is pure and depends only on `dart:typed_data`, so
/// it is unit-testable without a Flutter binding or a device. That matters:
/// a channel swap or a plane-order mistake surfaces as ML Kit returning zero
/// text blocks rather than as an error, which is close to undebuggable from
/// the symptom alone.
library;

import 'dart:typed_data';

/// Raw RGBA pixels decoded from an encoded image, held in memory only.
class RgbaImage {
  final int width;
  final int height;

  /// Four bytes per pixel, row-major, in R-G-B-A order.
  final Uint8List pixels;

  const RgbaImage({
    required this.width,
    required this.height,
    required this.pixels,
  });
}

/// Pure conversions between RGBA and the pixel formats ML Kit accepts.
class PixelConversion {
  PixelConversion._();

  /// Trims a trailing row and/or column when either dimension is odd.
  ///
  /// NV21 stores one chroma sample per 2×2 pixel block and has no defined
  /// behaviour at an odd edge. Cropping before conversion — rather than
  /// inside it — keeps the reported dimensions consistent with the pixels
  /// ML Kit actually saw, which is what the bounding-box normalization
  /// downstream is measured against.
  ///
  /// Returns the original instance unchanged when both dimensions are
  /// already even.
  static RgbaImage cropToEvenDimensions(RgbaImage image) {
    final width = image.width - (image.width % 2);
    final height = image.height - (image.height % 2);
    if (width == image.width && height == image.height) return image;

    final cropped = Uint8List(width * height * 4);
    final srcStride = image.width * 4;
    final dstStride = width * 4;
    for (var row = 0; row < height; row++) {
      cropped.setRange(
        row * dstStride,
        (row + 1) * dstStride,
        image.pixels,
        row * srcStride,
      );
    }

    return RgbaImage(width: width, height: height, pixels: cropped);
  }

  /// Swaps the red and blue channels to produce BGRA8888 for iOS.
  ///
  /// Does not modify [rgba].
  static Uint8List rgbaToBgra8888(Uint8List rgba) {
    final bgra = Uint8List.fromList(rgba);
    for (var i = 0; i + 3 < bgra.length; i += 4) {
      final red = bgra[i];
      bgra[i] = bgra[i + 2];
      bgra[i + 2] = red;
    }
    return bgra;
  }

  /// Converts RGBA pixels to NV21 for Android.
  ///
  /// NV21 is a full-resolution luma plane of `width * height` bytes followed
  /// by a half-resolution interleaved chroma plane ordered **V then U**,
  /// giving `width * height * 3 / 2` bytes in total.
  ///
  /// Uses the BT.601 studio-swing coefficients Android's NV21 pipeline
  /// expects, so luma lands in 16–235 rather than 0–255. [width] and
  /// [height] must both be even; call [cropToEvenDimensions] first.
  static Uint8List rgbaToNv21(Uint8List rgba, int width, int height) {
    assert(width.isEven && height.isEven, 'NV21 requires even dimensions');

    final lumaSize = width * height;
    final nv21 = Uint8List(lumaSize + lumaSize ~/ 2);

    var lumaIndex = 0;
    var chromaIndex = lumaSize;

    for (var row = 0; row < height; row++) {
      for (var col = 0; col < width; col++) {
        final pixel = (row * width + col) * 4;
        final red = rgba[pixel];
        final green = rgba[pixel + 1];
        final blue = rgba[pixel + 2];

        final luma = ((66 * red + 129 * green + 25 * blue + 128) >> 8) + 16;
        nv21[lumaIndex++] = luma.clamp(0, 255);

        // One chroma pair per 2×2 block, sampled at the block's top-left
        // pixel rather than averaged — cheaper, and OCR reads luma anyway.
        if (row.isEven && col.isEven) {
          final u = ((-38 * red - 74 * green + 112 * blue + 128) >> 8) + 128;
          final v = ((112 * red - 94 * green - 18 * blue + 128) >> 8) + 128;
          nv21[chromaIndex++] = v.clamp(0, 255);
          nv21[chromaIndex++] = u.clamp(0, 255);
        }
      }
    }

    return nv21;
  }
}

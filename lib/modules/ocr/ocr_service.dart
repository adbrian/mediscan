import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'pixel_conversion.dart';

/// A single text element (word or token) with its normalized bounding box.
class OcrTextElement {
  /// The recognized text content of this element.
  final String text;

  /// Bounding box normalized to 0–1 fractions of image dimensions.
  final ui.Rect boundingBox;

  const OcrTextElement({required this.text, required this.boundingBox});
}

/// A single line of text with its constituent elements and normalized bounding box.
class OcrTextLine {
  /// The full text of this line.
  final String text;

  /// Bounding box normalized to 0–1 fractions of image dimensions.
  final ui.Rect boundingBox;

  /// Individual word-level elements within this line.
  final List<OcrTextElement> elements;

  const OcrTextLine({
    required this.text,
    required this.boundingBox,
    required this.elements,
  });
}

/// A block of text containing one or more lines, with a normalized bounding box.
class OcrTextBlock {
  /// The full text of this block (all lines concatenated).
  final String text;

  /// Individual lines within this block.
  final List<OcrTextLine> lines;

  /// Bounding box normalized to 0–1 fractions of image dimensions.
  final ui.Rect boundingBox;

  const OcrTextBlock({
    required this.text,
    required this.lines,
    required this.boundingBox,
  });
}

/// Result of OCR processing, containing all recognized text blocks and the
/// source image dimensions (needed for bounding-box normalization downstream).
class OcrResult {
  /// All recognized text blocks in the image.
  final List<OcrTextBlock> blocks;

  /// Width of the source image in pixels.
  final int imageWidth;

  /// Height of the source image in pixels.
  final int imageHeight;

  const OcrResult({
    required this.blocks,
    required this.imageWidth,
    required this.imageHeight,
  });
}

/// On-device OCR service wrapping Google ML Kit Text Recognition.
///
/// All processing runs entirely on-device — no network calls are made, and
/// **no lab-report image is ever written to disk**. ML Kit is fed through
/// [InputImage.fromBytes] rather than `fromFilePath` precisely so that
/// captures never leave memory; see the standing constraints in CLAUDE.md.
///
/// Bounding boxes are normalized to 0–1 fractions of the image dimensions
/// so downstream modules (PII stripping, row reconstruction) can work with
/// position-independent coordinates.
class OcrService {
  TextRecognizer? _textRecognizer;

  /// Lazily initializes the ML Kit text recognizer.
  TextRecognizer get _recognizer {
    _textRecognizer ??= TextRecognizer();
    return _textRecognizer!;
  }

  /// Processes a raw image (PNG/JPEG bytes) and returns structured OCR results.
  ///
  /// Steps:
  /// 1. Decode the encoded bytes to raw RGBA pixels in memory.
  /// 2. Crop to even dimensions (NV21's 2×2 chroma subsampling requires it).
  /// 3. Convert to the platform's expected pixel format and hand ML Kit the
  ///    bytes directly.
  /// 4. Convert [RecognizedText] to our [OcrResult] model with normalized
  ///    bounding boxes.
  ///
  /// Returns an empty result for images too small to carry a chroma plane.
  Future<OcrResult> processImage(Uint8List imageBytes) async {
    final decoded = PixelConversion.cropToEvenDimensions(
      await _decodeToRgba(imageBytes),
    );

    if (decoded.width < 2 || decoded.height < 2) {
      return OcrResult(
        blocks: const [],
        imageWidth: decoded.width,
        imageHeight: decoded.height,
      );
    }

    final recognizedText = await _recognizer.processImage(
      _toInputImage(decoded),
    );

    return OcrResult(
      blocks: _convertBlocks(
        recognizedText.blocks,
        decoded.width,
        decoded.height,
      ),
      imageWidth: decoded.width,
      imageHeight: decoded.height,
    );
  }

  /// Decodes encoded image bytes (PNG/JPEG) to raw RGBA pixels.
  ///
  /// Flutter's decoder applies EXIF orientation during decode, which is why
  /// [_toInputImage] can declare [InputImageRotation.rotation0deg] — the
  /// pixels are already upright. Verify this on a physical device with a
  /// rotated camera capture before trusting it in the field.
  Future<RgbaImage> _decodeToRgba(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final data = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (data == null) {
          throw StateError('Could not read raw pixels from the decoded image.');
        }
        return RgbaImage(
          width: image.width,
          height: image.height,
          // Respect the view's own offset and length rather than taking the
          // whole backing buffer, which may be larger or start later.
          pixels: data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          ),
        );
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  /// Wraps decoded pixels as an [InputImage] in the format the platform's
  /// ML Kit binding accepts.
  ///
  /// Android takes NV21; iOS takes BGRA8888. Neither accepts encoded PNG or
  /// JPEG bytes, which is why the decode above is unavoidable.
  InputImage _toInputImage(RgbaImage image) {
    final size = ui.Size(image.width.toDouble(), image.height.toDouble());

    if (Platform.isIOS) {
      return InputImage.fromBytes(
        bytes: PixelConversion.rgbaToBgra8888(image.pixels),
        metadata: InputImageMetadata(
          size: size,
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.bgra8888,
          bytesPerRow: image.width * 4,
        ),
      );
    }

    return InputImage.fromBytes(
      bytes: PixelConversion.rgbaToNv21(
        image.pixels,
        image.width,
        image.height,
      ),
      metadata: InputImageMetadata(
        size: size,
        rotation: InputImageRotation.rotation0deg,
        format: InputImageFormat.nv21,
        // Stride of the full-resolution Y plane, one byte per pixel.
        bytesPerRow: image.width,
      ),
    );
  }

  /// Converts ML Kit [TextBlock] list to our [OcrTextBlock] model with
  /// bounding boxes normalized to 0–1 fractions of image dimensions.
  List<OcrTextBlock> _convertBlocks(
    List<TextBlock> mlBlocks,
    int imageWidth,
    int imageHeight,
  ) {
    return mlBlocks.map((mlBlock) {
      final lines = mlBlock.lines.map((mlLine) {
        final elements = mlLine.elements.map((mlElement) {
          return OcrTextElement(
            text: mlElement.text,
            boundingBox: _normalizeRect(
              mlElement.boundingBox,
              imageWidth,
              imageHeight,
            ),
          );
        }).toList();

        return OcrTextLine(
          text: mlLine.text,
          boundingBox: _normalizeRect(
            mlLine.boundingBox,
            imageWidth,
            imageHeight,
          ),
          elements: elements,
        );
      }).toList();

      return OcrTextBlock(
        text: mlBlock.text,
        lines: lines,
        boundingBox: _normalizeRect(
          mlBlock.boundingBox,
          imageWidth,
          imageHeight,
        ),
      );
    }).toList();
  }

  /// Normalizes a pixel-space bounding box [rect] to 0–1 fractions.
  ///
  /// ML Kit returns bounding boxes in pixel coordinates. We normalize them
  /// so that position-based classification (header/footer zones) works
  /// regardless of image resolution.
  ui.Rect _normalizeRect(ui.Rect rect, int imageWidth, int imageHeight) {
    return ui.Rect.fromLTRB(
      (rect.left / imageWidth).clamp(0.0, 1.0),
      (rect.top / imageHeight).clamp(0.0, 1.0),
      (rect.right / imageWidth).clamp(0.0, 1.0),
      (rect.bottom / imageHeight).clamp(0.0, 1.0),
    );
  }

  /// Releases ML Kit resources. Call when the service is no longer needed.
  void dispose() {
    _textRecognizer?.close();
    _textRecognizer = null;
  }
}

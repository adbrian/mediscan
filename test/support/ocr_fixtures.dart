import 'dart:ui' as ui;

import 'package:mediscan/modules/ocr/ocr_service.dart';

/// Fixture builders for the OCR path.
///
/// Coordinates are already normalized to 0–1, matching what `OcrService`
/// delivers after dividing ML Kit's pixel boxes by the image dimensions.

/// A line positioned by its vertical centre, which is what row grouping and
/// zone classification both key on.
OcrTextLine ocrLine(
  String text, {
  required double center,
  double height = 0.02,
  double left = 0.05,
  double width = 0.2,
}) {
  final top = center - height / 2;
  return OcrTextLine(
    text: text,
    boundingBox: ui.Rect.fromLTRB(left, top, left + width, top + height),
    elements: const [],
  );
}

ui.Rect _envelope(List<OcrTextLine> lines) => lines.isEmpty
    ? ui.Rect.zero
    : lines.map((l) => l.boundingBox).reduce((a, b) => a.expandToInclude(b));

/// Builds an [OcrResult] from one list of lines per ML Kit block.
///
/// ML Kit returns a block per visual column, so each inner list represents a
/// column rather than a row.
OcrResult ocrResult(List<List<OcrTextLine>> blocks) => OcrResult(
      blocks: [
        for (final lines in blocks)
          OcrTextBlock(
            text: lines.map((l) => l.text).join('\n'),
            lines: lines,
            boundingBox: _envelope(lines),
          ),
      ],
      imageWidth: 1240,
      imageHeight: 1754,
    );

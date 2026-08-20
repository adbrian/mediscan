import 'dart:math' as math;

import 'package:mediscan/modules/ocr/ocr_service.dart';

/// A logical table row reconstructed from OCR text lines.
///
/// ML Kit returns text blocks per visual column, not per table row. This class
/// represents a single logical row formed by grouping lines that share the same
/// vertical position on the page.
class ReconstructedRow {
  /// The concatenated text of all lines in this row, ordered left-to-right.
  final String text;

  /// Normalized top edge of the row's combined bounding box (0–1).
  final double normalizedTop;

  /// Normalized bottom edge of the row's combined bounding box (0–1).
  final double normalizedBottom;

  /// The original OCR lines that were grouped into this row.
  final List<OcrTextLine> sourceLines;

  const ReconstructedRow({
    required this.text,
    required this.normalizedTop,
    required this.normalizedBottom,
    required this.sourceLines,
  });
}

/// Reconstructs logical table rows from OCR output.
///
/// This is the highest-risk piece of the extraction pipeline. ML Kit returns
/// text blocks organized by visual columns (parameter name block, value block,
/// unit block, reference range block), not by table rows. Before regex
/// classification can work, we must group lines into logical rows.
///
/// Algorithm:
/// 1. Flatten all lines from all blocks.
/// 2. Calculate the median line height as a grouping tolerance reference.
/// 3. Group lines whose vertical centers are within ±0.5 × median line height.
/// 4. Sort each group left-to-right by horizontal position.
/// 5. Concatenate text with tab separators and track bounding boxes.
class RowReconstructor {
  RowReconstructor._();

  /// Reconstructs logical table rows from an [OcrResult].
  ///
  /// Returns rows sorted top-to-bottom by their vertical center position.
  static List<ReconstructedRow> reconstructRows(OcrResult ocrResult) {
    // Step 1: Flatten all lines from all blocks.
    final allLines = <OcrTextLine>[];
    for (final block in ocrResult.blocks) {
      allLines.addAll(block.lines);
    }

    if (allLines.isEmpty) return [];

    // Step 2: Calculate median line height for grouping tolerance.
    final lineHeights = allLines
        .map((line) => line.boundingBox.bottom - line.boundingBox.top)
        .where((h) => h > 0)
        .toList()
      ..sort();

    if (lineHeights.isEmpty) return [];

    final medianHeight = lineHeights[lineHeights.length ~/ 2];
    final tolerance = medianHeight * 0.5;

    // Step 3: Sort lines by vertical center, then group by proximity.
    final sortedLines = List<OcrTextLine>.from(allLines)
      ..sort((a, b) {
        final centerA = (a.boundingBox.top + a.boundingBox.bottom) / 2;
        final centerB = (b.boundingBox.top + b.boundingBox.bottom) / 2;
        return centerA.compareTo(centerB);
      });

    final groups = <List<OcrTextLine>>[];
    var currentGroup = <OcrTextLine>[sortedLines.first];
    var currentGroupCenter =
        (sortedLines.first.boundingBox.top + sortedLines.first.boundingBox.bottom) / 2;

    for (var i = 1; i < sortedLines.length; i++) {
      final line = sortedLines[i];
      final lineCenter = (line.boundingBox.top + line.boundingBox.bottom) / 2;

      if ((lineCenter - currentGroupCenter).abs() <= tolerance) {
        // This line belongs to the current row group.
        currentGroup.add(line);
        // Update group center to running average for stability.
        currentGroupCenter = currentGroup.fold<double>(
              0.0,
              (sum, l) =>
                  sum + (l.boundingBox.top + l.boundingBox.bottom) / 2,
            ) /
            currentGroup.length;
      } else {
        // Start a new group.
        groups.add(currentGroup);
        currentGroup = [line];
        currentGroupCenter = lineCenter;
      }
    }
    groups.add(currentGroup);

    // Step 4 & 5: Sort each group left-to-right, build ReconstructedRow.
    final rows = <ReconstructedRow>[];
    for (final group in groups) {
      // Sort left-to-right within the row.
      group.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));

      // Concatenate text with tab separators (preserves column structure
      // for downstream regex matching).
      final text = group.map((line) => line.text).join('\t');

      // Compute the combined bounding box for the row.
      final top = group
          .map((line) => line.boundingBox.top)
          .reduce(math.min);
      final bottom = group
          .map((line) => line.boundingBox.bottom)
          .reduce(math.max);

      rows.add(ReconstructedRow(
        text: text,
        normalizedTop: top,
        normalizedBottom: bottom,
        sourceLines: List.unmodifiable(group),
      ));
    }

    // Sort rows top-to-bottom by their vertical position.
    rows.sort((a, b) => a.normalizedTop.compareTo(b.normalizedTop));

    return rows;
  }
}

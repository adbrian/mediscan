import 'package:mediscan/modules/ocr/ocr_service.dart';
import 'package:mediscan/modules/pii_stripping/position_classifier.dart';
import 'package:mediscan/modules/pii_stripping/regex_rules.dart';
import 'package:mediscan/modules/pii_stripping/row_reconstructor.dart';

/// A single line after PII stripping classification.
class StrippedLine {
  /// The text content of this line.
  final String text;

  /// Whether this line was positively identified as safe medical data.
  final bool isRetained;

  /// Whether this line matched neither retain nor discard patterns.
  /// Ambiguous lines are passed through but flagged for extra scrutiny
  /// during normalization.
  final bool isAmbiguous;

  /// If this line contains a collection/report date, the extracted date string.
  final String? detectedDate;

  const StrippedLine({
    required this.text,
    required this.isRetained,
    this.isAmbiguous = false,
    this.detectedDate,
  });
}

/// Allowlist-based PII stripping service (fail-closed).
///
/// **Default action: DISCARD.** A line survives only if it positively matches
/// a retain pattern (parameter-value-unit or collection date). The discard
/// regexes are a secondary defense, not the primary mechanism.
///
/// Supports two input paths:
/// - **OCR path** ([stripFromOcr]): uses positional zone classification
///   (header/footer/content) plus content regex rules.
/// - **PDF text-layer path** ([stripFromTextLines]): uses content regex rules
///   only (no positional data available since text-layer extraction loses
///   bounding boxes).
class PiiStrippingService {
  /// Strips PII from OCR output using positional + content rules.
  ///
  /// 1. Reconstructs logical table rows from OCR blocks.
  /// 2. Classifies each row by position zone.
  /// 3. Applies content rules within the content zone.
  /// 4. Exception: collection date lines in header/footer are retained.
  List<StrippedLine> stripFromOcr(OcrResult ocrResult) {
    final rows = RowReconstructor.reconstructRows(ocrResult);
    final result = <StrippedLine>[];

    for (final row in rows) {
      final zone = PositionClassifier.classify(
        row.normalizedTop,
        row.normalizedBottom,
      );

      switch (zone) {
        case PositionZone.header:
        case PositionZone.footer:
          // Header/footer zones are discarded by default, UNLESS the line
          // contains a collection date (e.g. DDRC Agilus prints "DRAWN:"
          // in the header area).
          if (RegexRules.matchesCollectionDate(row.text)) {
            result.add(StrippedLine(
              text: row.text,
              isRetained: true,
              detectedDate: RegexRules.extractDate(row.text),
            ));
          }
          // Otherwise: silently discard — this is the fail-closed default.
          break;

        case PositionZone.content:
          result.add(_classifyLine(row.text));
          break;
      }
    }

    return result;
  }

  /// Strips PII from PDF text-layer lines using content rules only.
  ///
  /// The text-layer path has no positional data (bounding boxes are not
  /// available from Syncfusion text extraction), so only regex-based
  /// content classification is applied.
  List<StrippedLine> stripFromTextLines(List<String> lines) {
    return lines.map(_classifyLine).toList();
  }

  /// Classifies a single text line using the allowlist rules engine.
  ///
  /// Decision order (first match wins):
  /// 1. Collection date pattern → RETAIN with extracted date
  /// 2. Parameter-value-unit pattern → RETAIN
  /// 3. Any PII discard pattern → DISCARD
  /// 4. None of the above → AMBIGUOUS (passed through but flagged)
  StrippedLine _classifyLine(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return StrippedLine(text: trimmed, isRetained: false);
    }

    // 1. Check collection date pattern → retain with date extraction.
    if (RegexRules.matchesCollectionDate(trimmed)) {
      return StrippedLine(
        text: trimmed,
        isRetained: true,
        detectedDate: RegexRules.extractDate(trimmed),
      );
    }

    // 2. Check retain pattern (parameter-value-unit) → retain.
    if (RegexRules.matchesRetain(trimmed)) {
      return StrippedLine(text: trimmed, isRetained: true);
    }

    // 3. Check discard patterns (secondary defense) → discard.
    if (RegexRules.matchesAnyDiscard(trimmed)) {
      return StrippedLine(text: trimmed, isRetained: false);
    }

    // 4. Neither retain nor discard → ambiguous.
    // Ambiguous lines are passed through but flagged. The normalization
    // module will attempt to parse them; if they don't yield a valid
    // reading, they'll be silently dropped.
    return StrippedLine(
      text: trimmed,
      isRetained: false,
      isAmbiguous: true,
    );
  }
}

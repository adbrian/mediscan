/// Positional zone classifier for OCR bounding boxes.
///
/// Lab reports follow a predictable layout: patient demographics and lab
/// headers occupy the top of each page, footers contain signatures and
/// disclaimers, and the actual results table sits in the middle. This
/// classifier uses normalized vertical positions (0–1) to categorize text
/// blocks into zones, enabling the PII stripping module to discard header
/// and footer content without needing content-based heuristics.
library;

/// The vertical zone of a text element on a lab report page.
enum PositionZone {
  /// Top 20% of the page — typically contains lab header, patient
  /// demographics (name, age, gender, IDs), and doctor references.
  header,

  /// Bottom 15% of the page — typically contains signatures, QR codes,
  /// disclaimers, lab address, and patient reference numbers.
  footer,

  /// Middle 65% of the page — the results band where parameter-value-unit
  /// data lives. Content rules (regex) are applied to lines in this zone.
  content,
}

/// Classifies text blocks into positional zones based on their normalized
/// vertical position on the page.
class PositionClassifier {
  PositionClassifier._();

  /// Classifies a text element's vertical position into a [PositionZone].
  ///
  /// [normalizedTop] and [normalizedBottom] are the top and bottom edges of
  /// the bounding box as fractions of the page height (0.0 = top of page,
  /// 1.0 = bottom of page).
  ///
  /// The classification uses the vertical center of the bounding box:
  /// - Center ≤ 0.20 → [PositionZone.header]
  /// - Center ≥ 0.85 → [PositionZone.footer]
  /// - Otherwise → [PositionZone.content]
  static PositionZone classify(
    double normalizedTop,
    double normalizedBottom,
  ) {
    final center = (normalizedTop + normalizedBottom) / 2;
    if (center <= 0.20) return PositionZone.header;
    if (center >= 0.85) return PositionZone.footer;
    return PositionZone.content;
  }
}

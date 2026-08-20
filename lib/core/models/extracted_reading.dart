/// Model representing a single extracted and normalized health parameter reading
/// from a lab report. Created by the normalization pipeline after PII stripping.
library;

/// Confidence level of the parameter name match against the canonical dictionary.
enum MatchConfidence {
  /// Exact match found in variant dictionary.
  high,

  /// Fuzzy match above threshold (≥0.85 similarity).
  medium,

  /// No match found — requires user resolution on confirmation screen.
  unrecognized,
}

/// A single structured reading extracted from a lab report line.
///
/// Contains the canonical parameter identification, the measured value,
/// unit, and optional reference range. Also preserves the raw source name
/// for traceability (e.g. "LDL CHOLESTEROL, DIRECT" → `ldl_cholesterol`).
class ExtractedReading {
  /// The raw parameter name as it appeared on the lab report, before
  /// normalization. Preserved so the user can see what was originally scanned.
  final String rawName;

  /// Canonical parameter name (e.g. `hemoglobin`, `fasting_glucose`).
  /// Null when [confidence] is [MatchConfidence.unrecognized].
  final String? canonicalName;

  /// Human-readable display name (e.g. "Hemoglobin", "Fasting Blood Sugar").
  /// Null when [confidence] is [MatchConfidence.unrecognized].
  final String? displayName;

  /// The numeric measurement value, or `null` if parsing failed.
  final double? value;

  /// The normalized unit string (e.g. "mg/dL", "g/dL", "%"), or `null` if
  /// the unit could not be determined.
  final String? unit;

  /// The unit string exactly as the OCR engine read it, before normalization.
  final String? rawUnit;

  /// Lower bound of the reference range, if available.
  final double? refLow;

  /// Upper bound of the reference range, if available.
  final double? refHigh;

  /// Display string for the reference range (e.g. "<200", ">40", "13.0–17.0").
  final String? refDisplay;

  /// Confidence level of the parameter name match.
  final MatchConfidence confidence;

  /// Whether the user has selected this reading for import.
  ///
  /// Defaults to `true` — all readings start selected on the confirmation
  /// screen.
  final bool isSelected;

  /// Inline flag from the lab report (e.g. "High", "Low"), if present.
  final String? inlineFlag;

  const ExtractedReading({
    required this.rawName,
    this.canonicalName,
    this.displayName,
    this.value,
    this.unit,
    this.rawUnit,
    this.refLow,
    this.refHigh,
    this.refDisplay,
    this.confidence = MatchConfidence.unrecognized,
    this.isSelected = true,
    this.inlineFlag,
  });

  /// Whether this reading was successfully matched to a canonical parameter.
  bool get isRecognized => confidence != MatchConfidence.unrecognized;

  /// Returns a copy of this reading with the given fields replaced.
  ExtractedReading copyWith({
    String? rawName,
    String? canonicalName,
    String? displayName,
    double? value,
    String? unit,
    String? rawUnit,
    double? refLow,
    double? refHigh,
    String? refDisplay,
    MatchConfidence? confidence,
    bool? isSelected,
    String? inlineFlag,
  }) {
    return ExtractedReading(
      rawName: rawName ?? this.rawName,
      canonicalName: canonicalName ?? this.canonicalName,
      displayName: displayName ?? this.displayName,
      value: value ?? this.value,
      unit: unit ?? this.unit,
      rawUnit: rawUnit ?? this.rawUnit,
      refLow: refLow ?? this.refLow,
      refHigh: refHigh ?? this.refHigh,
      refDisplay: refDisplay ?? this.refDisplay,
      confidence: confidence ?? this.confidence,
      isSelected: isSelected ?? this.isSelected,
      inlineFlag: inlineFlag ?? this.inlineFlag,
    );
  }

  @override
  String toString() {
    final name = displayName ?? rawName;
    return 'ExtractedReading($name: $value $unit, '
        'confidence: ${confidence.name})';
  }
}

/// PII detection and medical data retention regex patterns.
///
/// MediScan uses an allowlist-based (fail-closed) approach: the default action
/// for every line is DISCARD. A line is retained only if it positively matches
/// a retain pattern. The discard patterns act as a secondary defense.
///
/// Patterns are derived from the MediScan product spec and tuned against real
/// Indian lab report formats (DDRC Agilus, Thyrocare, SRL, Apollo, etc.).
library;

class RegexRules {
  RegexRules._();

  // ---------------------------------------------------------------------------
  // DISCARD patterns — lines matching any of these contain PII
  // ---------------------------------------------------------------------------

  /// Matches "Name:" or "Patient Name:" header lines.
  static final patientName = RegExp(
    r'(Patient\s)?Name\s*:',
    caseSensitive: false,
  );

  /// Matches age/gender patterns like "39 Years Male", "25 Yrs / F".
  static final ageGender = RegExp(
    r'\d{1,3}\s?(Y(rs)?|Years?)\s*[\/\\]\s*(M|F|Male|Female)',
    caseSensitive: false,
  );

  /// Matches standalone "Sex:" or "Gender:" labels.
  static final genderAlone = RegExp(
    r'^(Sex|Gender)\s*:',
    caseSensitive: false,
  );

  /// Matches patient ID fields: UHID, MRN, Patient ID, Registration No,
  /// Accession No, ABHA No (DDRC Agilus specific).
  static final idNumbers = RegExp(
    r'(UHID|MRN|Patient\s?ID|Reg(istration)?\s?(No|Number)|ACCESSION(\s?NO)?|ABHA(\s?NO)?)\s*:',
    caseSensitive: false,
  );

  /// Matches 10-digit Indian mobile numbers starting with 6–9.
  static final phoneNumber = RegExp(r'\b[6-9]\d{9}\b');

  /// Matches email addresses.
  static final email = RegExp(
    r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}',
  );

  /// Matches 6-digit Indian PIN codes.
  static final pinCode = RegExp(r'\b\d{6}\b');

  /// Matches doctor/referral lines.
  static final doctorRef = RegExp(
    r'(Ref(erred)?\s?[Bb]y|Consultant|Dr\.)\s*:',
    caseSensitive: false,
  );

  /// Matches common Indian address tokens.
  static final addressTokens = RegExp(
    r'\b(Road|Street|Nagar|Colony|Layout|Phase|Sector|Block)\b',
    caseSensitive: false,
  );

  /// Matches "Patient Ref" (DDRC Agilus footer field).
  static final patientRef = RegExp(
    r'Patient\s*Ref',
    caseSensitive: false,
  );

  // ---------------------------------------------------------------------------
  // RETAIN patterns — lines matching these contain medical data to keep
  // ---------------------------------------------------------------------------

  /// Matches parameter-value-unit patterns found in lab result tables.
  ///
  /// Examples:
  /// - "Hemoglobin    15.2    g/dL"
  /// - "Total Cholesterol    185    mg/dL"
  /// - "WBC Count    8.4    10^3/µL"
  static final parameterValueUnit = RegExp(
    r'[A-Za-z][\w\s\(\)\.\/-]{2,40}\s+\d+(\.\d+)?\s*(mg\/dL|g\/dL|%|mIU\/L|IU\/L|mmol\/L|cells\/[\u03bcu]L|10\^3\/[\u03bcu]L|U\/L|ng\/mL|pg\/mL|fL|pg|g\/L|thou\/[\u03bcu]L|mil\/[\u03bcu]L|mm\/hr|mmHg|\u00b5g\/dL|x10\^3\/uL|x10\^6\/uL|K\/uL|M\/uL)',
    caseSensitive: false,
  );

  /// Matches collection/report date lines.
  ///
  /// Examples:
  /// - "Collected On: 27/06/2026"
  /// - "Sample Date: 15-03-2025"
  /// - "DRAWN :27/06/2026 08:02:50"
  static final collectionDate = RegExp(
    r'(Collected|Sample|Collection|Reported|Report|DRAWN)\s*(Date|On|:)\s*:?\s*\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4}',
    caseSensitive: false,
  );

  /// Extracts a date string from text (dd/mm/yyyy, dd-mm-yyyy, dd.mm.yyyy).
  static final dateExtractor = RegExp(
    r'(\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4})',
  );

  // ---------------------------------------------------------------------------
  // Convenience — aggregated access
  // ---------------------------------------------------------------------------

  /// All PII discard patterns, checked in order.
  static final List<RegExp> allDiscardPatterns = [
    patientName,
    ageGender,
    genderAlone,
    idNumbers,
    phoneNumber,
    email,
    pinCode,
    doctorRef,
    addressTokens,
    patientRef,
  ];

  /// Returns `true` if [text] matches any PII discard pattern.
  static bool matchesAnyDiscard(String text) {
    return allDiscardPatterns.any((pattern) => pattern.hasMatch(text));
  }

  /// Returns `true` if [text] matches the parameter-value-unit retain pattern.
  static bool matchesRetain(String text) {
    return parameterValueUnit.hasMatch(text);
  }

  /// Returns `true` if [text] matches the collection date retain pattern.
  static bool matchesCollectionDate(String text) {
    return collectionDate.hasMatch(text);
  }

  /// Extracts the first date string found in [text], or `null` if none found.
  static String? extractDate(String text) {
    final match = dateExtractor.firstMatch(text);
    return match?.group(0);
  }
}

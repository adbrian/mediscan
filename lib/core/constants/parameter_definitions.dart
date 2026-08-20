/// Canonical parameter registry for MediScan.
///
/// This file is the single source of truth for all supported lab parameters,
/// their reference ranges, name variants (for OCR matching), and unit
/// normalization rules.
class ParameterDefinitions {
  ParameterDefinitions._();

  // ---------------------------------------------------------------------------
  // A) Canonical parameter list — 15 parameters across 4 panels
  // ---------------------------------------------------------------------------

  /// Every recognised lab parameter with its default metadata.
  ///
  /// Fields per entry:
  /// - `canonicalName`  — unique snake_case key used throughout the app
  /// - `displayName`    — human‑readable label shown in the UI
  /// - `unit`           — default display unit
  /// - `refLow`         — lower bound of normal range (nullable)
  /// - `refHigh`        — upper bound of normal range (nullable)
  /// - `refDisplay`     — formatted reference‑range string shown to the user
  /// - `panel`          — logical grouping
  static const List<Map<String, dynamic>> canonicalParameters = [
    // ── Blood Sugar ──────────────────────────────────────────────────────────
    {
      'canonicalName': 'fasting_glucose',
      'displayName': 'Fasting Blood Sugar',
      'unit': 'mg/dL',
      'refLow': 70.0,
      'refHigh': 100.0,
      'refDisplay': '70–100',
      'panel': 'blood_sugar',
    },
    {
      'canonicalName': 'postprandial_glucose',
      'displayName': 'Postprandial Blood Sugar',
      'unit': 'mg/dL',
      'refLow': null,
      'refHigh': 140.0,
      'refDisplay': '<140',
      'panel': 'blood_sugar',
    },
    {
      'canonicalName': 'hba1c',
      'displayName': 'HbA1c',
      'unit': '%',
      'refLow': 4.0,
      'refHigh': 5.6,
      'refDisplay': '4.0–5.6',
      'panel': 'blood_sugar',
    },
    {
      'canonicalName': 'random_glucose',
      'displayName': 'Random Blood Sugar',
      'unit': 'mg/dL',
      'refLow': null,
      'refHigh': 200.0,
      'refDisplay': '<200',
      'panel': 'blood_sugar',
    },

    // ── Lipid Profile ────────────────────────────────────────────────────────
    {
      'canonicalName': 'total_cholesterol',
      'displayName': 'Total Cholesterol',
      'unit': 'mg/dL',
      'refLow': null,
      'refHigh': 200.0,
      'refDisplay': '<200',
      'panel': 'lipid',
    },
    {
      'canonicalName': 'hdl_cholesterol',
      'displayName': 'HDL Cholesterol',
      'unit': 'mg/dL',
      'refLow': 40.0,
      'refHigh': null,
      'refDisplay': '>40',
      'panel': 'lipid',
    },
    {
      'canonicalName': 'ldl_cholesterol',
      'displayName': 'LDL Cholesterol',
      'unit': 'mg/dL',
      'refLow': null,
      'refHigh': 100.0,
      'refDisplay': '<100',
      'panel': 'lipid',
    },
    {
      'canonicalName': 'triglycerides',
      'displayName': 'Triglycerides',
      'unit': 'mg/dL',
      'refLow': null,
      'refHigh': 150.0,
      'refDisplay': '<150',
      'panel': 'lipid',
    },
    {
      'canonicalName': 'vldl_cholesterol',
      'displayName': 'VLDL Cholesterol',
      'unit': 'mg/dL',
      'refLow': 2.0,
      'refHigh': 30.0,
      'refDisplay': '2–30',
      'panel': 'lipid',
    },

    // ── Complete Blood Count ─────────────────────────────────────────────────
    {
      'canonicalName': 'hemoglobin',
      'displayName': 'Hemoglobin',
      'unit': 'g/dL',
      'refLow': 13.0,
      'refHigh': 17.0,
      'refDisplay': '13.0–17.0',
      'panel': 'cbc',
    },
    {
      'canonicalName': 'wbc_count',
      'displayName': 'WBC Count',
      'unit': '10³/μL',
      'refLow': 4.0,
      'refHigh': 11.0,
      'refDisplay': '4.0–11.0',
      'panel': 'cbc',
    },
    {
      'canonicalName': 'platelet_count',
      'displayName': 'Platelet Count',
      'unit': '10³/μL',
      'refLow': 150.0,
      'refHigh': 400.0,
      'refDisplay': '150–400',
      'panel': 'cbc',
    },
    {
      'canonicalName': 'rbc_count',
      'displayName': 'RBC Count',
      'unit': '10⁶/μL',
      'refLow': 4.5,
      'refHigh': 5.5,
      'refDisplay': '4.5–5.5',
      'panel': 'cbc',
    },

    // ── Vitals ───────────────────────────────────────────────────────────────
    {
      'canonicalName': 'bp_systolic',
      'displayName': 'Blood Pressure (Systolic)',
      'unit': 'mmHg',
      'refLow': 90.0,
      'refHigh': 120.0,
      'refDisplay': '90–120',
      'panel': 'vitals',
    },
    {
      'canonicalName': 'bp_diastolic',
      'displayName': 'Blood Pressure (Diastolic)',
      'unit': 'mmHg',
      'refLow': 60.0,
      'refHigh': 80.0,
      'refDisplay': '60–80',
      'panel': 'vitals',
    },
  ];

  // ---------------------------------------------------------------------------
  // B) Parameter name variants — maps canonical key → OCR‑friendly aliases
  // ---------------------------------------------------------------------------

  /// Lookup table used by the OCR matcher to resolve scanned text to a
  /// canonical parameter name. Keys are canonical names; values are lists of
  /// strings that the OCR engine might return for that parameter.
  static const Map<String, List<String>> parameterVariants = {
    'fasting_glucose': [
      'FBS',
      'Fasting Blood Sugar',
      'Fasting Glucose',
      'Glu-F',
      'F. Blood Sugar',
      'Blood Glucose Fasting',
      'Glucose Fasting',
      'Fasting Sugar',
      'Blood Sugar Fasting',
      'Fasting Plasma Glucose',
      'FPG',
      'Glucose (Fasting)',
      'FBS-FASTING BLOOD SUGAR(GLUCOSE)',
    ],
    'postprandial_glucose': [
      'PPBS',
      'PP Blood Sugar',
      'Postprandial Blood Sugar',
      'Post Prandial Blood Sugar',
      'Glucose PP',
      'PPBG',
      'Blood Sugar PP',
      '2 Hr Post Prandial',
      'Post Meal Blood Sugar',
      'Blood Glucose PP',
    ],
    'hba1c': [
      'HbA1c',
      'HBA1C',
      'Glycated Hemoglobin',
      'Glycosylated Hemoglobin',
      'A1c',
      'GHb',
      'Hemoglobin A1c',
      'HbA1C (%)',
      'Glyco Hb',
      'Glycated Hb',
    ],
    'random_glucose': [
      'RBS',
      'Random Blood Sugar',
      'Random Glucose',
      'Blood Sugar Random',
      'Glucose Random',
    ],
    'total_cholesterol': [
      'Total Cholesterol',
      'Cholesterol Total',
      'Cholesterol',
      'TC',
      'Serum Cholesterol',
      'Chol',
      'CHOLESTEROL, TOTAL',
    ],
    'hdl_cholesterol': [
      'HDL',
      'HDL Cholesterol',
      'HDL-C',
      'Good Cholesterol',
      'High Density Lipoprotein',
      'HDL-Cholesterol',
      'HDL CHOLESTEROL',
    ],
    'ldl_cholesterol': [
      'LDL',
      'LDL Cholesterol',
      'LDL-C',
      'Bad Cholesterol',
      'Low Density Lipoprotein',
      'LDL-Cholesterol',
      'LDL (Calculated)',
      'LDL CHOLESTEROL, DIRECT',
      'LDL Cholesterol Direct',
    ],
    'triglycerides': [
      'Triglycerides',
      'TG',
      'Triglyceride',
      'Trigs',
      'TRIGLYCERIDES',
      'Serum Triglycerides',
    ],
    'vldl_cholesterol': [
      'VLDL',
      'VLDL Cholesterol',
      'VLDL-C',
      'Very Low Density Lipoprotein',
      'VERY LOW DENSITY LIPOPROTEIN',
    ],
    'hemoglobin': [
      'Hemoglobin',
      'Haemoglobin',
      'Hb',
      'HGB',
      'Hgb',
      'HEMOGLOBIN',
    ],
    'wbc_count': [
      'WBC Count',
      'WBC',
      'White Blood Cell Count',
      'Total WBC Count',
      'TLC',
      'Total Leucocyte Count',
      'WHITE BLOOD CELL COUNT',
    ],
    'rbc_count': [
      'RBC Count',
      'RBC',
      'Red Blood Cell Count',
      'Total RBC Count',
      'RED BLOOD CELL COUNT',
    ],
    'platelet_count': [
      'Platelet Count',
      'Platelets',
      'PLT',
      'Total Platelet Count',
      'PLATELET COUNT',
    ],
    'bp_systolic': [
      'Systolic BP',
      'Systolic',
      'SBP',
      'Systolic Blood Pressure',
    ],
    'bp_diastolic': [
      'Diastolic BP',
      'Diastolic',
      'DBP',
      'Diastolic Blood Pressure',
    ],
  };

  // ---------------------------------------------------------------------------
  // C) Unit normalization — maps canonical unit → OCR variants
  // ---------------------------------------------------------------------------

  /// Maps a canonical unit string to the various representations that might
  /// appear on a scanned lab report.  The matcher normalises any variant to
  /// the canonical key.
  static const Map<String, List<String>> unitVariants = {
    'mg/dL': ['mg/dl', 'mg/DL', 'MG/DL'],
    'g/dL': ['g/dl', 'G/DL', 'gm/dL', 'gm/dl'],
    '%': ['percent'],
    '10³/μL': [
      'thou/µL',
      'thou/uL',
      'x10^3/uL',
      'K/µL',
      'K/uL',
      '10^3/uL',
      '10³/µL',
      'x10³/µL',
      'thousand/uL',
    ],
    '10⁶/μL': [
      'mil/µL',
      'mil/uL',
      'x10^6/uL',
      'M/µL',
      'M/uL',
      '10^6/uL',
      '10⁶/µL',
      'million/uL',
    ],
    'U/L': ['u/L', 'IU/L', 'iu/L'],
    'ng/mL': ['ng/ml'],
    'pg/mL': ['pg/ml'],
    'fL': ['fl', 'femtolitre', 'femtoliter'],
    'pg': ['picogram'],
    'mmHg': ['mm Hg', 'mmhg', 'mm hg'],
    'mIU/L': ['µIU/mL', 'uIU/mL'],
  };

  // ---------------------------------------------------------------------------
  // D) Panel display names
  // ---------------------------------------------------------------------------

  /// Human‑readable panel names keyed by internal identifier.
  static const Map<String, String> panelDisplayNames = {
    'blood_sugar': 'Blood Sugar',
    'lipid': 'Lipid Profile',
    'cbc': 'Complete Blood Count',
    'vitals': 'Vitals',
    'custom': 'Custom',
  };
}

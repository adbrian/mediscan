# MediScan — Product Outline for Development

## Overview

MediScan is a privacy-first Flutter mobile application that allows users to scan periodic medical lab reports, extract structured health data, and track trends over time. All health data is stored exclusively on the user's device. The service provider never holds, transmits, or has access to any user health data.

**Platform:** iOS and Android (single Flutter codebase)  
**Language:** Dart  
**Minimum Target:** Android 8.0 (API 26) / iOS 13.0  

---

## Core Principle

> All user health data stays on the device at all times. There is no backend, no cloud database, no user account server, and no external API calls in V1.

---

## Tech Stack

| Layer | Technology | Package |
|---|---|---|
| Mobile framework | Flutter | — |
| OCR | Google ML Kit Text Recognition | `google_mlkit_text_recognition` |
| PII stripping | Custom Dart rules engine | — |
| Parameter normalization | Dart mapping dictionary + Levenshtein fuzzy match | `string_similarity` or custom |
| Local database | SQLite + SQLCipher (AES-256) | `sqflite_sqlcipher` |
| Encryption key management | Android Keystore / iOS Secure Enclave | `flutter_secure_storage` |
| Trend charts | fl_chart | `fl_chart` |
| PDF rendering | PDF to image conversion | `pdfx` |
| Camera | Flutter camera | `image_picker` |

---

## Application Flow

```
1. User captures image (camera) or imports PDF
        ↓
2. ML Kit OCR — on-device text extraction
   Returns: text blocks with bounding box coordinates + confidence scores
        ↓
3. PII Stripping — Dart rules engine
   Input:  raw text blocks with positions
   Output: de-identified results lines only
        ↓
4. Parameter Normalization — local dictionary + fuzzy matching
   Input:  de-identified results lines
   Output: structured list of { canonical_name, value, unit, ref_range, date }
        ↓
5. Confirmation Screen — user reviews and approves
   User can: edit values, correct date, remove rows, map unknown parameters
   Nothing is saved until user taps Confirm
        ↓
6. SQLCipher encrypted local database — write confirmed records
        ↓
7. Trend Visualization — line charts per parameter with reference range bands
```

---

## Module Specifications

---

### Module 1 — Image Capture & PDF Import

**Responsibilities:**
- Provide a camera capture interface within the app
- Allow import of PDF files from device storage
- Convert PDF pages to images (one image per page)
- Pass image to OCR module

**Requirements:**
- Camera capture must use the device's native camera via `image_picker`
- **PDF text-layer first:** If an imported PDF contains an embedded text layer (true for most digitally generated lab PDFs, e.g. DDRC Agilus), extract the text directly (`syncfusion_flutter_pdf` or equivalent, on-device) and skip OCR entirely. This yields perfect character accuracy. Rasterize + OCR is the fallback path used only for scanned/image-only PDFs and camera captures. Note: text-layer extraction loses ML Kit bounding boxes, so the PII stripping module must handle both positional input (OCR path) and line-order-only input (text-layer path).
- PDF import must support multi-page PDFs; each page is processed as a separate image when the OCR path is used
- Images are held in memory only — never written to shared storage or gallery
- After OCR processing, the image is discarded from memory
- Support both portrait and landscape report orientations

**Acceptance Criteria:**
- User can capture an image using the in-app camera
- User can import a PDF from device storage
- Multi-page PDFs are split into individual page images
- No image file is written to device gallery or shared storage at any point

---

### Module 2 — On-Device OCR (ML Kit)

**Responsibilities:**
- Process the captured/imported image using ML Kit Text Recognition
- Return structured text blocks with positional metadata

**Requirements:**
- Use `google_mlkit_text_recognition` — on-device model only, no network call
- Extract text as a list of `TextBlock` objects, each containing:
  - Raw text content
  - Bounding box (normalised coordinates: top, bottom, left, right as fractions of image dimensions)
  - Constituent lines and elements with their own bounding boxes
- Pass the full structured block list (text + positions) to the PII Stripping module
- Do not flatten to a plain string before PII stripping — positional data is required

**Acceptance Criteria:**
- OCR runs entirely on-device with no network call
- Output includes bounding box coordinates per text block
- Raw OCR output is accessible in a debug/developer mode screen for QA verification

---

### Module 3 — PII Stripping (Dart Rules Engine)

**Responsibilities:**
- Classify every text block as either safe (results data) or PII (discard)
- Return only safe lines for further processing

**Fail-closed principle (mandatory):** The module operates as an **allowlist**, not a blocklist. The default action for every line is DISCARD. A line survives only if it positively matches a retain pattern (parameter-value-unit, or collection date). The PII discard regexes below act as a *second* defensive check on lines that passed the allowlist — they are not the primary mechanism. This ensures that an unanticipated PII format (a new header layout, a name without a "Name:" label) is dropped by default rather than leaked by default.

**Classification uses two signals:**

#### Signal A — Positional rules (applied first)

| Zone | Action |
|---|---|
| Top 20% of page height | Discard (lab header, patient demographics) |
| Bottom 15% of page height | Discard (footer, signatures, disclaimers) |
| Middle 65% of page height | Apply content rules (Signal B) |

Exception: lines in the top/bottom zones that match a **collection date pattern** are retained.

#### Signal B — Content pattern matching (regex)

**Discard if line matches any of:**

```
Patient name:     /(Patient\s)?Name\s*:/i
Age/Gender:       /\d{1,3}\s?(Y(rs)?|Years?)\s*[\/\\]\s*(M|F|Male|Female)/i
Gender alone:     /^(Sex|Gender)\s*:/i
ID numbers:       /(UHID|MRN|Patient\s?ID|Reg(istration)?\s?(No|Number))\s*:/i
Phone numbers:    /\b[6-9]\d{9}\b/
Email:            /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/
PIN code:         /\b\d{6}\b/
Doctor/Referral:  /(Ref(erred)?\s?[Bb]y|Consultant|Dr\.)\s*:/i
Address tokens:   /\b(Road|Street|Nagar|Colony|Layout|Phase|Sector|Block)\b/i
```

**Retain if line matches:**

```
Parameter-value-unit pattern:
/[A-Za-z][\w\s\(\)\.\/\-]{2,40}\s+\d+(\.\d+)?\s*(mg\/dL|g\/dL|%|mIU\/L|IU\/L|mmol\/L|cells\/[μu]L|10\^3\/[μu]L|U\/L|ng\/mL|pg\/mL|fL|pg|g\/L)/i

Collection date pattern:
/(Collected|Sample|Collection|Reported|Report)\s*(Date|On|:)\s*\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4}/i
```

**Row reconstruction (OCR path only — critical prerequisite):** ML Kit returns text *blocks*, not table rows. In a columnar lab report, the parameter name, value, reference range, and unit are frequently returned as **separate blocks** (one per column). Before any regex classification, blocks must be reconstructed into logical rows by grouping blocks whose vertical bounding-box centres fall within a tolerance band (suggest ±0.5 × median line height), sorted left-to-right. The retain patterns are then applied to the reconstructed row string. Treat this as its own sub-component with its own unit tests — it is the highest-risk piece of the extraction pipeline. (The PDF text-layer path largely avoids this problem since extraction preserves reading order.)

**Requirements:**
- Processing must be synchronous and complete within 500ms on a mid-range device
- No network call at any point in this module
- Lines that match neither retain nor discard pattern are held separately as "ambiguous" — passed to normalization but flagged
- The module must be independently unit-testable with a fixed set of sample text blocks

**Acceptance Criteria:**
- Patient name, age, gender, ID numbers, address, doctor name, phone, email are not present in the output
- All parameter-value-unit lines from the results table are present in the output
- Collection date is present in the output
- Validated against a test library of at least 10 real lab report samples from different labs

---

### Module 4 — Parameter Normalization

**Responsibilities:**
- Map raw extracted parameter names to canonical internal parameter names
- Handle OCR misreads via fuzzy matching
- Flag unrecognized parameters for user resolution

#### Canonical Parameter List (V1)

**Panel: Blood Sugar**

| Canonical Name | Display Name | Unit | Ref Range |
|---|---|---|---|
| `fasting_glucose` | Fasting Blood Sugar | mg/dL | 70–100 |
| `postprandial_glucose` | Postprandial Blood Sugar | mg/dL | <140 |
| `hba1c` | HbA1c | % | 4.0–5.6 |
| `random_glucose` | Random Blood Sugar | mg/dL | <200 |

**Panel: Lipid Profile**

| Canonical Name | Display Name | Unit | Ref Range |
|---|---|---|---|
| `total_cholesterol` | Total Cholesterol | mg/dL | <200 |
| `hdl_cholesterol` | HDL Cholesterol | mg/dL | >40 (M), >50 (F) |
| `ldl_cholesterol` | LDL Cholesterol | mg/dL | <100 |
| `triglycerides` | Triglycerides | mg/dL | <150 |
| `vldl_cholesterol` | VLDL Cholesterol | mg/dL | 2–30 |

**Panel: CBC**

| Canonical Name | Display Name | Unit | Ref Range |
|---|---|---|---|
| `hemoglobin` | Hemoglobin | g/dL | 13.0–17.0 (M), 12.0–15.0 (F) |
| `wbc_count` | WBC Count | 10³/μL | 4.0–11.0 |
| `platelet_count` | Platelet Count | 10³/μL | 150–400 |
| `rbc_count` | RBC Count | 10⁶/μL | 4.5–5.5 (M), 4.0–5.0 (F) |

**Vitals (manual entry only)**

| Canonical Name | Display Name | Unit |
|---|---|---|
| `bp_systolic` | Blood Pressure (Systolic) | mmHg |
| `bp_diastolic` | Blood Pressure (Diastolic) | mmHg |

#### Variant Dictionary (sample — implement fully for all parameters)

```dart
const Map<String, List<String>> parameterVariants = {
  'fasting_glucose': [
    'FBS', 'Fasting Blood Sugar', 'Fasting Glucose', 'Glu-F',
    'F. Blood Sugar', 'Blood Glucose Fasting', 'Glucose Fasting',
    'Fasting Sugar', 'Blood Sugar Fasting', 'Fasting Plasma Glucose',
    'FPG', 'Glucose (Fasting)'
  ],
  'hba1c': [
    'HbA1c', 'HBA1C', 'Glycated Hemoglobin', 'Glycosylated Hemoglobin',
    'A1c', 'GHb', 'Hemoglobin A1c', 'HbA1C (%)', 'Glyco Hb'
  ],
  'total_cholesterol': [
    'Total Cholesterol', 'Cholesterol Total', 'Cholesterol',
    'TC', 'Serum Cholesterol', 'Chol'
  ],
  'hdl_cholesterol': [
    'HDL', 'HDL Cholesterol', 'HDL-C', 'Good Cholesterol',
    'High Density Lipoprotein', 'HDL-Cholesterol'
  ],
  'ldl_cholesterol': [
    'LDL', 'LDL Cholesterol', 'LDL-C', 'Bad Cholesterol',
    'Low Density Lipoprotein', 'LDL-Cholesterol', 'LDL (Calculated)'
  ],
  'hemoglobin': [
    'Hemoglobin', 'Haemoglobin', 'Hb', 'HGB', 'Hgb'
  ],
  'wbc_count': [
    'WBC Count', 'WBC', 'White Blood Cell Count', 'Total WBC Count',
    'TLC', 'Total Leucocyte Count'
  ],
  'rbc_count': [
    'RBC Count', 'RBC', 'Red Blood Cell Count', 'Total RBC Count'
  ],
  'platelet_count': [
    'Platelet Count', 'Platelets', 'PLT', 'Total Platelet Count'
  ],
  // DDRC Agilus observed forms (see Known Lab Formats appendix):
  //   'HBA1C', 'FBS-FASTING BLOOD SUGAR(GLUCOSE)', 'CHOLESTEROL, TOTAL',
  //   'LDL CHOLESTEROL, DIRECT', 'WHITE BLOOD CELL COUNT', 'RED BLOOD CELL COUNT'
  // ... extend for all parameters
};
```

**Compound-name handling:** Some labs prefix or suffix qualifiers, e.g. `FBS-FASTING BLOOD SUGAR(GLUCOSE)` or `LDL CHOLESTEROL, DIRECT`. Normalization must match on token overlap, not whole-string equality: strip punctuation, split into tokens, and match if a known variant is contained within the token set. Both `LDL CHOLESTEROL, DIRECT` (measured) and `LDL (Calculated)` map to `ldl_cholesterol`; store the raw source name alongside the canonical name in the reading so the method distinction is not lost.

**Unit normalization:** Units also vary across labs and must have their own variant map — e.g. `thou/µL`, `10³/µL`, `x10^3/uL`, `K/µL` all mean thousands per microlitre; `mil/µL` and `10⁶/µL` both mean millions per microlitre; `mg/dl` vs `mg/dL`. Values must be stored with a single canonical unit per parameter; if a lab reports in a different but convertible unit (e.g. mmol/L glucose), V1 flags it for user confirmation rather than auto-converting.

#### Normalization Logic

```
1. Clean input string: lowercase, strip punctuation, trim whitespace
2. Exact match against all variants (case-insensitive)
   → if match found: assign canonical name, confidence = HIGH
3. Fuzzy match using Levenshtein distance
   → similarity threshold: >= 0.85 (tune based on testing)
   → if match found above threshold: assign canonical name, confidence = MEDIUM
4. No match found:
   → flag as UNRECOGNIZED
   → pass raw name to confirmation screen for user resolution
```

**Acceptance Criteria:**
- All 15 canonical parameters are correctly identified from at least 10 sample reports
- OCR misreads (e.g. `HbAlc` with lowercase L, `Haemog1obin` with digit 1) are correctly matched via fuzzy matching
- Unrecognized parameters are flagged and not silently dropped
- Normalization runs entirely on-device with no network call

---

### Module 5 — Confirmation Screen

**Responsibilities:**
- Display all extracted parameters for user review before any database write
- Allow user to correct misread values, dates, or parameter mappings
- Handle unrecognized parameters
- Write to database only on explicit user confirmation

**UI Requirements:**

Display a scrollable list with one row per extracted parameter:
```
[ ✓ ] Fasting Blood Sugar        98   mg/dL     Ref: 70–100
[ ✓ ] HbA1c                     6.2   %         Ref: 4.0–5.6
[ ✓ ] Total Cholesterol         185   mg/dL     Ref: <200
[ ⚠ ] "Eosinophils %"           —    UNRECOGNIZED  [ Map ] [ Skip ]
```

**Per-row interactions:**
- Tap value field → inline numeric keyboard to correct value
- Tap parameter name → dropdown to remap to a known canonical parameter
- Tap delete icon → remove row from this scan
- For UNRECOGNIZED rows: [ Map to known parameter ] or [ Add as custom ] or [ Skip ]

**Header section:**
- Report date (editable — tapping opens date picker)
- Optional lab name (free text, user-entered, not captured from OCR)

**Footer actions:**
- [ Confirm & Save ] — writes all checked rows to database
- [ Discard Scan ] — discards everything, returns to home screen

**Hard rules:**
- The Confirm & Save button must be disabled until the user has resolved all UNRECOGNIZED rows (either mapped, added as custom, or explicitly skipped)
- No database write occurs before Confirm & Save is tapped
- If the user navigates back from this screen, nothing is saved

**Acceptance Criteria:**
- All extracted parameters are displayed with value, unit, and reference range
- User can edit any value before saving
- User can remove any row
- Unrecognized parameters are clearly highlighted and require explicit resolution
- Database is empty after a scan if user taps Discard
- Database contains exactly the confirmed rows after user taps Confirm & Save

---

### Module 6 — Encrypted Local Storage

**Database:** SQLite encrypted with SQLCipher (AES-256)  
**Package:** `sqflite_sqlcipher`  
**Key storage:** `flutter_secure_storage` (backed by Android Keystore / iOS Secure Enclave)

#### Schema

```sql
-- Canonical parameter definitions
CREATE TABLE parameters (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  canonical_name TEXT NOT NULL UNIQUE,
  display_name  TEXT NOT NULL,
  default_unit  TEXT NOT NULL,
  ref_low       REAL,
  ref_high      REAL,
  ref_display   TEXT,        -- e.g. "<200" or ">40" for non-range references
  panel         TEXT NOT NULL,   -- 'blood_sugar' | 'lipid' | 'cbc' | 'vitals' | 'custom'
  is_custom     INTEGER DEFAULT 0
);

-- Individual scan sessions
CREATE TABLE reports (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  scan_date     TEXT NOT NULL,    -- ISO 8601 date of scan
  test_date     TEXT NOT NULL,    -- ISO 8601 date on the lab report
  lab_name      TEXT,             -- optional, user-entered
  notes         TEXT              -- optional free text
);

-- Individual parameter readings
CREATE TABLE readings (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  report_id     INTEGER NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
  parameter_id  INTEGER NOT NULL REFERENCES parameters(id),
  value         REAL NOT NULL,
  unit          TEXT NOT NULL,
  ref_low       REAL,             -- ref range at time of this reading (may differ from default)
  ref_high      REAL,
  ref_display   TEXT,
  entry_type    TEXT DEFAULT 'scan',  -- 'scan' | 'manual'
  created_at    TEXT NOT NULL     -- ISO 8601 timestamp
);
```

#### Date Handling & Out-of-Order Scanning

Users will scan reports in arbitrary order — a 2023 report may be scanned after a 2026 one. The historical view must always be correct regardless of scan order.

**Rules:**

1. **`test_date` is the single source of truth for chronology.** All trend charts, sparklines, "latest value" displays, and history lists sort and plot by `test_date`, never by `scan_date`, `created_at`, or row insertion order.
2. **`test_date` = specimen collection date.** When a report carries multiple dates (DDRC Agilus prints DRAWN, RECEIVED, and REPORTED), extract the **DRAWN / Collected / Sample** date — that is when the measurement physically reflects the user's health. Fall back to REPORTED date only if no collection date is found, and pre-fill the confirmation screen date field so the user can verify it.
3. **`scan_date` / `created_at` are audit metadata only** — when the user scanned/saved. Never used for ordering health data.
4. **"Latest value" is a query, not a cached write.** The dashboard's most-recent value per parameter must be computed as `MAX(test_date)` at read time, so scanning an old report never overwrites the display of a newer result.
5. **Duplicate detection.** Before saving, check for an existing report with the same `test_date`; if one exists and shares ≥50% of parameters with overlapping values, warn the user: "You may have already scanned a report from this date" with options to view the existing report, save anyway, or cancel. Do not silently create duplicates — duplicate points corrupt trend charts.
6. **Same-day multiple reports are legitimate** (e.g. fasting morning draw + evening PP test), which is why duplicate detection warns rather than blocks.

**Acceptance Criteria (add to Module 6):**
- Scanning reports in the order 2026 → 2023 → 2025 produces an identically ordered chart to scanning them 2023 → 2025 → 2026
- Dashboard "latest value" remains the 2026 value after an older report is scanned
- Scanning the same report twice triggers the duplicate warning

#### Key Management

```
On first app launch:
  1. Generate a random 256-bit encryption key
  2. Store key in flutter_secure_storage
     → Android: backed by Android Keystore, bound to device lock screen
     → iOS: backed by Secure Enclave, accessible only with biometric/passcode
  3. Open SQLCipher database with this key

On subsequent launches:
  1. Retrieve key from flutter_secure_storage
  2. Open SQLCipher database with retrieved key
  3. If key retrieval fails (e.g. biometric not authenticated): show lock screen, do not open DB
```

**Requirements:**
- The encryption key must never appear in app logs, analytics, or plain text files
- **Do not bind the key to biometric enrolment state.** On Android, keys created with `setInvalidatedByBiometricEnrollment(true)` are permanently destroyed if the user adds/removes a fingerprint — which would make the database unrecoverable. Gate *access* behind biometric/PIN at the app level, but the key material itself must survive biometric re-enrolment. Verify `flutter_secure_storage` configuration accordingly on both platforms.
- The database file must be stored in the app's private data directory (not shared storage)
- App data must be excluded from Android Auto Backup and iOS iCloud Backup
  - Android: set `android:allowBackup="false"` in AndroidManifest.xml, or use backup rules to exclude the DB file
  - iOS: set `NSURLIsExcludedFromBackupKey` on the database file path

**Acceptance Criteria:**
- Database file is unreadable when opened directly (e.g. via adb pull) without the encryption key
- App correctly opens database after biometric authentication on relaunch
- No health data appears in Google Drive or iCloud backup (validated by QA)
- Cascading delete: deleting a report deletes all associated readings

---

### Module 7 — Trend Visualization

**Package:** `fl_chart`

**Screens:**

**Home / Dashboard**
- List of all panels (Blood Sugar, Lipid Profile, CBC, Vitals)
- Each panel shows the parameters tracked within it
- For each parameter: display most recent value + date, and a small sparkline

**Parameter Detail Screen**
- Full-size line chart: x-axis = **test_date** (never scan date), y-axis = measurement value
- Reference range displayed as a horizontal shaded band (green = within range)
- Data points are tappable — tap shows exact value and date in a tooltip
- Date range filter: All / Last 6 months / Last 1 year / Last 2 years
- Toggle between chart view and table view (list of readings with date and value)

**Report History Screen**
- List of all scan sessions grouped by date
- Each session shows all parameters captured in that scan
- Tap a session to see the full reading set from that visit

**Manual Entry Screen**
- Simple form: parameter selector (blood pressure only in V1), value fields, date picker
- Manual entries are visually distinguished on charts (e.g. dashed line or different marker shape)

**Acceptance Criteria:**
- Line chart renders correctly for a parameter with readings across 2+ years
- Reference range band is visible and correctly positioned
- Tapping a data point shows correct value and date
- Chart renders correctly with only one data point (no crash, shows single marker)
- Manual and scanned entries are both plotted and visually distinguished

---

### Module 8 — Security & Privacy Hardening

**Requirements:**

- **App lock:** Require biometric / device PIN authentication on every app launch and when returning from background after more than 5 minutes
- **Screenshot prevention:** Set `FLAG_SECURE` on Android (prevents screenshots and app switcher preview). Use equivalent on iOS (`ignoresSiblingOrder` + blank overlay on `willResignActive`)
- **No analytics:** No Firebase, no Crashlytics, no third-party analytics SDK in V1. No data leaves the device for telemetry.
- **No crash reporting:** Implement local-only error logging (write to a local text file, never transmitted)
- **Backup exclusion:** Explicitly exclude database file from all cloud backup mechanisms (Android + iOS)
- **Privacy policy screen:** Accessible from app settings. Must state clearly: what data is collected (none, by the service provider), where data is stored (on-device only), and what happens on uninstall (all data is deleted)
- **App store declarations:** Complete Apple App Privacy nutrition label and Google Play Data Safety form accurately — declare no data collected or shared

---

## Project Structure (Suggested)

```
lib/
  main.dart
  app.dart
  
  core/
    database/
      database_service.dart       # SQLCipher init, key management
      migrations/
    models/
      parameter.dart
      reading.dart
      report.dart
    constants/
      parameter_definitions.dart  # canonical list, variant dictionary, ref ranges
  
  modules/
    capture/
      camera_screen.dart
      pdf_import_service.dart
    
    ocr/
      ocr_service.dart            # ML Kit wrapper
    
    pii_stripping/
      pii_stripping_service.dart  # rules engine
      position_classifier.dart
      regex_rules.dart
    
    normalization/
      normalization_service.dart
      fuzzy_matcher.dart
      parameter_variants.dart     # the variant dictionary
    
    confirmation/
      confirmation_screen.dart
      confirmation_row_widget.dart
      unrecognized_parameter_widget.dart
    
    visualization/
      home_screen.dart
      parameter_detail_screen.dart
      report_history_screen.dart
      manual_entry_screen.dart
      widgets/
        trend_chart_widget.dart
        sparkline_widget.dart
        reading_table_widget.dart
    
    settings/
      settings_screen.dart
      privacy_policy_screen.dart
  
  shared/
    widgets/
    theme/
    utils/
```

---

## Testing Requirements

### Unit Tests (required for all modules)

- `pii_stripping_service_test.dart` — test against 20+ sample text block inputs, assert correct classification
- `normalization_service_test.dart` — test all 15 canonical parameters with all known variants + OCR misread variants
- `fuzzy_matcher_test.dart` — test similarity thresholds with edge cases
- `database_service_test.dart` — test CRUD operations, cascading delete, schema integrity

### Integration Tests

- Full scan-to-storage flow test using sample OCR output fixtures (no live camera needed)
- Confirmation screen → database write → chart rendering end-to-end

### QA Test Library

Maintain a folder of at least 10 anonymised real lab report images (or synthetic equivalents) covering:
- **DDRC Agilus format (first confirmed sample acquired — see appendix)**
- Thyrocare report format
- SRL Diagnostics format
- Apollo Diagnostics format
- Generic hospital format
- At least 2 reports with parameters named in non-standard ways

All 10 reports must pass the full pipeline with correct extraction and normalization before V1 is considered done.

---

## Appendix — Known Lab Formats

### DDRC Agilus Pathlabs (Kerala) — verified against real 17-page sample

**Layout:**
- Full patient header repeats on **every page** (top ~20%): patient name, accession no, patient ID, ABHA no, age/sex, phone number, DRAWN/RECEIVED/REPORTED timestamps, ref. doctor
- Footer (bottom ~15%): doctor signatures, QR codes, lab address, patient ref no — repeats every page
- Results in a 3-column band in the middle: parameter / value / reference-interval + unit
- Section headers in the results band: `HAEMATOLOGY`, `BIO CHEMISTRY`, `BIOCHEMISTRY - LIPID`, etc. — non-PII, discard as non-matching
- Long narrative `Interpretation(s)` blocks and reference tables appear inside the results band — the parameter-value-unit allowlist correctly rejects these
- Abnormal values carry an inline flag appended to the value: `8.4 High`, `46 High` — the value parser must strip trailing `High`/`Low` tokens (and may optionally capture them as a flag)

**Date fields:** `DRAWN :27/06/2026 08:02:50` is the collection date → use as `test_date`. Format DD/MM/YYYY HH:MM:SS.

**PII specifics observed:** standalone 10-digit phone on its own line; `ACCESSION NO :`, `PATIENT ID : FH.xxxxxxxx`, `ABHA NO :`, `Patient Ref. No.` — add `ACCESSION` and `ABHA` to the ID regex. Age/sex appears inline within a multi-field line (`AGE/SEX :39 Years Male`), not on a dedicated line.

**Parameter naming conventions observed:**
| DDRC form | Canonical |
|---|---|
| `HBA1C` | `hba1c` |
| `FBS-FASTING BLOOD SUGAR(GLUCOSE)` | `fasting_glucose` |
| `CHOLESTEROL, TOTAL` | `total_cholesterol` |
| `HDL CHOLESTEROL` | `hdl_cholesterol` |
| `LDL CHOLESTEROL, DIRECT` | `ldl_cholesterol` |
| `TRIGLYCERIDES` | `triglycerides` |
| `VERY LOW DENSITY LIPOPROTEIN` | `vldl_cholesterol` |
| `HEMOGLOBIN` | `hemoglobin` |
| `WHITE BLOOD CELL COUNT` | `wbc_count` |
| `RED BLOOD CELL COUNT` | `rbc_count` |
| `PLATELET COUNT` | `platelet_count` |

**Units observed:** `thou/µL` (thousands), `mil/µL` (millions), `mg/dL`, `mg/dl` (lowercase variant on the same report), `g/dL`, `%`, `µIU/mL`, `ng/mL`, `pg/mL`, `µg/dL`, `fL`, `pg`, `U/L`, `mm at 1 hr`, `/HPF`.

**Reference range formats observed:** plain ranges (`13.0 - 17.0`), thresholds (`< 116.0`, `Adults : < 40`), age-qualified (`18 - 60 yrs : 0.9 - 1.3`), and multi-line categorical blocks (HbA1c's Normal/Non-diabetic/Diabetic tiers). V1 rule: capture the first numeric range/threshold on the parameter's row; ignore multi-line interpretation tiers.

**Digital PDF:** DDRC reports are digitally generated with an embedded text layer → the PDF text-extraction path applies; OCR is only needed for photographed printouts of these reports.

---

## Out of Scope — V1

The following are explicitly deferred to future versions:

- Cloud sync or cross-device access
- Sharing reports with doctors
- ABDM / Ayushman Bharat Digital Mission integration
- AI-powered trend insights or recommendations
- Imaging reports (X-ray, MRI, ECG)
- Handwritten report support
- Web companion app
- Export / import of encrypted backup file *(high priority for V1.1)*
- Kidney, Liver, and Thyroid panels *(V1.1)*
- AI API fallback for unrecognized parameters *(V1.1 optional)*

---

## Definition of Done — V1

A user can:
1. Open the app and authenticate with biometric / PIN
2. Capture a lab report photo or import a PDF
3. Review the extracted parameters on the confirmation screen, correct any errors, and save
4. See a line chart of any parameter's history across multiple scans
5. Manually enter a blood pressure reading with a date
6. Access a privacy policy that accurately describes how their data is handled
7. Trust that at no point during any of the above did any health data leave their device

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What MediScan is

A privacy-first Flutter app (iOS + Android, Dart) that OCR-scans periodic lab
reports, extracts structured health readings, and charts trends over time.

**Non-negotiable core principle:** all health data stays on-device. No
backend, no cloud DB, no user accounts, no network calls, no analytics/crash
reporting SDKs in V1. Any change that would cause health data or PII to leave
the device is out of scope for V1 and should be flagged rather than
implemented.

**`mediscan_product_outline.md` is the authoritative spec.** It is long and
detailed — read the relevant module section directly before implementing
that module rather than relying on the summary below, especially for exact
regex patterns, the variant dictionary, and the DB schema.

**Where the work stands:** Phases 0 (unblock the build) and 1 (lock down the
existing modules with tests) of the completion plan are done. **Phase 2 —
normalization — is next**, and it is the missing link in the pipeline: nothing
currently converts a `StrippedLine` into an `ExtractedReading`. The plan,
including the phases after that, is kept current at
https://claude.ai/code/artifact/0d8e81ba-fa9c-4e49-9b84-a53131a7cf0b

## Standing constraints

These are settled decisions, not open questions. They override the spec where
they differ from it. Don't relitigate them; flag it if a task appears to
require breaking one.

1. **No networking dependencies, ever.** No HTTP client (`http`, `dio`), no
   analytics, no crash-reporting SDK, and no `dart:io` `HttpClient` usage
   anywhere under `lib/`. Enforced by `test/no_network_test.dart`, not by
   convention. It is the app's core invariant and the basis of the app-store
   privacy declarations.

   **The strongest control is the Android release manifest, which declares no
   `INTERNET` permission** — the OS refuses the syscall regardless of what is
   linked into the process. Never add it to
   `android/app/src/main/AndroidManifest.xml`; if a feature appears to need
   it, that feature is out of V1 scope. (The `debug` and `profile` manifests
   do declare it, for hot reload and the observatory. Those variants never
   ship, and the test asserts that difference so it reads as intentional.)

   **`http` is in the dependency tree and cannot be removed.** It arrives
   transitively via `syncfusion_flutter_pdf`, `image_picker`, and
   `file_picker`. So the claim is not "no HTTP client in the binary" — it is
   that no MediScan code calls one, and that Android release builds could not
   complete the call anyway. iOS has no equivalent permission gate, which is
   why the dependency and source controls are not redundant there.

   Residual risk to check on a device: a PDF referencing a remote font or
   image could in principle prompt Syncfusion to fetch it. Blocked on Android
   release by the manifest; **not** blocked on iOS. Verify with a PDF
   containing a remote resource before shipping.

   The direct-dependency set is pinned in that test. When it fires because you
   added a package, run `flutter pub deps --style=compact` and check what the
   package pulls in before updating the list — a transitive HTTP client is
   invisible in `pubspec.yaml`.
2. **No lab-report images are written to disk.** Feed ML Kit through
   `InputImage.fromBytes`, never `fromFilePath`. Where a plugin stages a file
   outside our control (`image_picker` writes to the Android cache dir; see
   `ImagePickerDelegate.java:601`), delete it immediately after reading its
   bytes. Images live in memory and are discarded after OCR.
3. **All chronological ordering is by `test_date`.** Never `scan_date`,
   `created_at`, or insertion order. "Latest value" is always a live
   `MAX(test_date)` query, never a cached or denormalized field.
4. **PII stripping stays allowlist-based and fail-closed.** The default action
   for any line is discard. Retention requires a positive match against a
   retain pattern. Discard regexes are a secondary defense and must never
   become the primary mechanism.
5. **Encrypted export/import is V1 scope**, not V1.1. Because the database is
   excluded from all cloud backup, export is the only recovery path a user
   has if they lose the device — shipping backup exclusion without it would
   mean a lost phone destroys the entire history irrecoverably.

**Reference ranges are captured per reading.** `readings.ref_low` /
`ref_high` / `ref_display` store whatever range the lab printed on that
specific report, which is how sex- and age-specific ranges are handled
without the app ever knowing the user's sex — consistent with PII stripping
discarding gender. The ranges seeded into `parameters` are a display fallback
for manual entries and for reports that omit ranges; they are single-valued
and do not vary by sex. Document that limitation in the UI where a fallback
range is shown.

## Commands

```bash
flutter pub get                    # install dependencies
flutter analyze                    # lint + type check (flutter_lints)
flutter test                       # run all tests (101 currently, all green)
flutter test test/foo_test.dart    # run a single test file
flutter test --name "pattern"      # run tests matching a name
flutter run                        # run on connected device/emulator
flutter build apk                  # Android release build
flutter build ios                  # iOS release build (needs macOS/Xcode)
```

Toolchain: Flutter 3.44.8 / Dart 3.12.2, stable channel. Android `minSdk = 26`
(raised from the Flutter default for SQLCipher + ML Kit).

## Build state

`flutter analyze` is clean and `flutter test` passes 101 tests. Run both before
and after your changes so you can tell your failures from anything
pre-existing.

**Nothing in this repo has ever run on a physical device.** The dev machine has
no Android or iOS device or emulator attached — `flutter devices` offers only
Linux desktop and Chrome, and this app's plugins (ML Kit, SQLCipher,
`image_picker`) support neither. A clean analyze and a green suite are the only
signals available here; treat "it compiles", "it passes", and "it works" as
three different claims.

### Unverified without a device

Every item below is load-bearing and has never executed. They are roughly
ordered by how much damage a silent failure would do. Work through them the
first time a device is available, before trusting any of the code that
depends on them.

1. **SQLCipher encryption itself.** The test seam replaces the real open call,
   so `_openWithSqlCipher` has zero coverage. Nothing anywhere verifies that
   data at rest is actually encrypted — which is the whole premise of the
   storage design.
2. **The encryption key surviving biometric re-enrollment.** If this is wrong
   the user's database is permanently unreadable, with no recovery path until
   encrypted export ships. Test by enrolling a new fingerprint and reopening.
3. **ML Kit accepting the NV21 / BGRA8888 buffers.** A channel or plane-order
   error returns zero text blocks rather than an error, so it presents as
   "OCR is bad" rather than as a conversion bug.
4. **EXIF orientation.** The code declares `rotation0deg` on the assumption
   that Flutter's decoder already applied EXIF. If it does not, rotated camera
   captures silently fail to recognise.
5. **Syncfusion fetching a remote resource referenced by a PDF, on iOS.**
   Android release blocks it via the absent `INTERNET` permission; iOS has no
   equivalent gate. This is the one open hole in the no-network invariant.

## Implementation status

Scaffolded and implemented:

- `lib/modules/capture/pdf_import_service.dart` — PDF text-layer extraction
  with rasterization fallback. Extracts per page with `layoutText: true`,
  which preserves the column spacing the retain regex matches against.
- `lib/modules/ocr/ocr_service.dart` — ML Kit wrapper. Decodes to RGBA in
  memory, crops to even dimensions, converts to NV21 (Android) or BGRA8888
  (iOS), and feeds `InputImage.fromBytes`. No image touches disk.
- `lib/modules/ocr/pixel_conversion.dart` — the RGBA → NV21 / BGRA8888
  conversions, split out as a pure unit with no Flutter dependency so it
  tests without a binding or a device. Tested.
- `lib/modules/pii_stripping/` — full rules engine (service, row
  reconstructor, position classifier, regexes).
- `lib/core/database/database_service.dart` — complete SQLCipher schema + CRUD,
  with a `withOpener` test seam (see Testing).
- `lib/core/models/` — `Report`, `Reading`, `Parameter`, `ExtractedReading`.
  `ExtractedReading` is the pipeline-internal model normalization is meant to
  produce; **nothing constructs one yet**.
- `lib/core/constants/parameter_definitions.dart` — canonical parameters,
  **variant dictionary, and unit-variant map** (see layout note below).
- `lib/shared/` — theme, date utils, `AppCard`. `AppTheme` is written but
  unreferenced, since `main.dart` is still the template.

Not yet written — check before assuming these exist:

- **Normalization** (`modules/normalization/`) — nothing. The variant data
  exists but no service consumes it: no fuzzy matcher, no unit normalizer, no
  code that produces an `ExtractedReading`. This is the gap between PII
  stripping and the confirmation screen.
- **Confirmation screen**, **visualization/home/detail screens**,
  **manual entry**, **settings** — none.
- **Biometric gate** — `local_auth` is a dependency but unused.
- `lib/main.dart` is still the `flutter create` template printing
  `Hello World!`; it does not use `AppTheme`, and there is no `app.dart`.

**Layout divergence from the spec:** the outline's "Project Structure" section
puts the variant dictionary at `modules/normalization/parameter_variants.dart`.
The actual code puts it in `core/constants/parameter_definitions.dart`
alongside the canonical list (sections B and C of that file). Follow the actual
layout; don't create a duplicate dictionary.

## Pipeline architecture

Data flows through a fixed sequence of modules, each independently
unit-testable, with a hard privacy checkpoint after OCR and before any
storage:

```
Capture (camera / PDF import)
  → OCR (ML Kit, on-device) OR PDF text-layer extraction (preferred when available)
  → PII Stripping (allowlist rules engine — fail-closed)
  → Parameter Normalization (variant dictionary + fuzzy match)   ← not built
  → Confirmation Screen (user must explicitly approve; nothing persists before this)
  → SQLCipher encrypted local DB
  → Trend Visualization (fl_chart)
```

Key architectural points that span multiple modules:

- **Two extraction paths feed the same downstream pipeline.** Digitally
  generated PDFs (most lab PDFs) use direct text-layer extraction and skip OCR
  — more accurate, and it preserves reading order. Camera captures and
  scanned/image-only PDFs fall back to ML Kit OCR; `PdfImportService` decides
  by measuring the text layer (needs ≥20 chars) and rasterizes at ~3× scale
  when it falls short. Consequently **PII stripping must handle both
  positional input (OCR bounding boxes) and line-order-only input**, which is
  why `PiiStrippingService` has two entry points: `stripFromOcr()` and
  `stripFromTextLines()`.
- **PII stripping is allowlist-based (fail-closed), not blocklist-based.**
  The default action for any line is discard; a line is retained only if it
  positively matches a retain pattern (parameter-value-unit, or collection
  date). The discard regexes in `RegexRules` are a secondary defense, not the
  primary mechanism. Any new PII-stripping logic must preserve this
  fail-closed default. Lines matching neither retain nor discard are emitted
  as `StrippedLine(isRetained: false, isAmbiguous: true)` — passed through for
  normalization to attempt, and silently dropped if they yield no valid
  reading. **`isRetained` is the gate; `isAmbiguous` is only a hint.** A caller
  that reads the returned list without filtering on `isRetained` leaks exactly
  the text the allowlist declined to vouch for.

  Classification order inside `_classifyLine` is collection date → retain →
  discard → ambiguous, and **retain preceding discard is load-bearing**: the
  PIN-code rule (`\b\d{6}\b`) matches any six-digit number, so reversing the
  order would silently drop every six-digit result value, platelet counts
  included. `test/pii_stripping_service_test.dart` pins this.

  Two defects that file also pins, both confirmed rather than theoretical:
  1. **Two-character parameter names are silently dropped.** The retain regex
     needs `[A-Za-z]` plus 2–40 more name characters before the whitespace
     separator, so a two-letter name leaves only one. `Hb`, `TG`, and `TC` are
     all in the variant dictionary, and `RowReconstructor` joins with a single
     tab — exactly the failing shape. Those readings never reach
     normalization. Three characters is enough, which is why `HDL` survives.
  2. **`RegexRules.ageGender` does not match what its comment claims.** The
     doc says it catches `39 Years Male`; the pattern requires a `/` or `\`
     separator, so the unseparated form matches no discard rule at all.
     Fail-closed still withholds it, so this is a documentation defect rather
     than a leak — but the blocklist has a hole that anything trusting it
     would inherit.

  Position beats content in the header and footer bands: only the
  collection-date exception is consulted there, so a results table starting
  unusually high on the page loses its top rows with no report of it.
- **OCR bounding boxes are normalized to 0–1 fractions of image dimensions**
  by `OcrService` before leaving the module, so `PositionClassifier`'s zone
  thresholds (header ≤0.20, footer ≥0.85, content between) are
  resolution-independent. Anything feeding `PositionClassifier` must be
  normalized the same way.
- **Row reconstruction is a distinct, high-risk sub-step** on the OCR path:
  ML Kit returns text blocks per column, not per table row, so
  `RowReconstructor` groups lines whose vertical centers fall within ±0.5×
  the median line height, sorts each group left-to-right, and joins with tabs.
  Regex classification cannot work before this runs. Treat it as its own
  testable unit.

  `test/row_reconstructor_test.dart` pins three known limitations, each marked
  `KNOWN LIMITATION` and each a silent-corruption path rather than an error:
  1. The tolerance uses the **global** median line height, so a page mixing
     font sizes over-groups the smaller section — several visually distinct
     lines collapse into one row. DDRC's METHOD sub-lines and reference tiers
     are in a smaller face than the results table, so this is live, not
     theoretical.
  2. A superscript raised past the tolerance orphans itself, leaving the
     parameter row with a unit that is *wrong* rather than missing
     (`10 /µL`), which nothing downstream flags.
  3. A value centred against a two-line wrapped parameter name splits into
     three rows and is lost entirely — the allowlist rejects the isolated
     bare number.

  Also pinned: at the tolerance boundary the grouping decision depends on how
  the coordinates were *computed*, not their nominal values (`0.83` and
  `0.80 + 3 * 0.01` are different doubles and group differently). Don't
  "fix" that with an epsilon without expecting extraction changes on real
  reports; the test will tell you.

  Any change to the tolerance rule must be run against this file — its whole
  purpose is to make such a change visible instead of silent.
- **`test_date` (specimen collection date) is the single source of truth for
  chronology** — all charts, "latest value" queries, and history views sort by
  `test_date`, never by `scan_date`/`created_at`/insertion order, since users
  may scan reports out of chronological order. "Latest value" must be a live
  query (`MAX(test_date)`), never a cached/denormalized field — see
  `getLatestReading()` and `getDashboardData()` for the correlated-subquery
  pattern to copy.
- **Confirmation screen is a hard gate**: no DB write happens before the user
  taps Confirm & Save, and Confirm & Save must stay disabled until every
  UNRECOGNIZED parameter row is resolved (mapped, added as custom, or
  explicitly skipped).
- **Encryption key must not be bound to biometric enrollment state.** Gate app
  *access* behind biometric/PIN, but the SQLCipher key itself (a 256-bit random
  key in `flutter_secure_storage`, generated on first launch) must survive
  re-enrollment. `DatabaseService` deliberately uses
  `AndroidOptions(encryptedSharedPreferences: true)`; Android's
  `setInvalidatedByBiometricEnrollment(true)` would permanently brick the
  database.
- **Duplicate detection** (`DatabaseService.findDuplicateReport`) treats a
  report as a duplicate when an existing report shares the same `test_date`
  *and* ≥50% of the incoming `parameter_id`s (threshold rounds up:
  `ceil(n / 2)`). The DB-layer check exists; no UI calls it yet.

  Consequence, pinned in `database_service_test.dart`: **two reports sharing a
  parameter's latest `test_date` make `getDashboardData()` return that
  parameter twice.** The query selects every reading whose report matches
  `MAX(test_date)`, with no tie-break. A split panel, or a re-scan the user
  did not recognise as a duplicate, therefore produces a doubled dashboard
  row. The fix is a tie-break in the query, best decided when the dashboard is
  actually built in Phase 5.

## Testing

Written so far (101 tests, all green): `pixel_conversion_test.dart`,
`row_reconstructor_test.dart`, `pii_stripping_service_test.dart`,
`no_network_test.dart`, `database_service_test.dart`.

Shared OCR fixture builders live in `test/support/ocr_fixtures.dart` — use
`ocrLine(text, center:)` and `ocrResult([...])` rather than hand-rolling
`ui.Rect`s, and note that each inner list is a *column*, since that is what ML
Kit returns.

Still outstanding, from the outline's § Testing Requirements:
`normalization_service_test.dart` (all 15 canonical parameters × every known
variant, plus OCR misreads like `HbAlc` and `Haemog1obin`) and
`fuzzy_matcher_test.dart` (similarity thresholds, ≥0.85 = medium confidence) —
both Phase 2, alongside the code they test — and the fixture-driven
scan-to-storage integration test that needs no live camera (Phase 3).

**House style for these tests**, established by the five already written and
worth continuing: when you find behaviour that is wrong but not yours to fix
in the moment, pin it with a test named `KNOWN LIMITATION:` or `KNOWN GAP:`
and a comment explaining the mechanism and the consequence. Seven such
tripwires exist (`grep -rn "KNOWN LIMITATION\|KNOWN GAP\|EDGE:" test/`). They
are not documentation of defeat — they turn a future silent behaviour change
into a failing test. Derive expected values
independently (from a spec, a formula, a published reference) rather than from
what the implementation currently returns, or the test records the code
instead of checking it.

Additionally, and not in the outline: **`no_network_test.dart` enforces
Standing constraint #1** through three layered controls — the absent Android
`INTERNET` permission, the dependency denylist plus pinned direct-dependency
set, and a source scan of `lib/`. Treat a failure there as a release blocker,
never as a test to update. See constraint #1 above for what the controls do
and do not cover.

`DatabaseService` keeps its production singleton (`DatabaseService.instance`)
but is now testable through `DatabaseService.withOpener(...)`, which injects
the three things a unit test cannot do: resolve the documents directory, read
secure storage, and open a SQLCipher database. Tests pass an
`sqflite_common_ffi` opener backed by `:memory:`.

**That seam means encryption is never exercised by the test suite.** The
injected opener replaces the SQLCipher call outright, so
`_openWithSqlCipher` is the one code path in the class with no coverage.
Neither "data at rest is encrypted" nor "the key survives biometric
re-enrollment" is verified anywhere — both need a device, and both matter more
than anything the tests do cover. The suite does assert that the resolved key
and path reach the opener, which catches a broken `_initDatabase` but not a
broken SQLCipher call.

## Reference material inside the outline

When implementing a module, go to its section directly for exact detail:

- Module 3 (PII Stripping) has the full positional-zone table and regexes.
- Module 4 (Normalization) has the canonical parameter list, the variant
  dictionary, unit-normalization rules, and token-overlap matching logic for
  compound names.
- Module 6 (Storage) has the full SQL schema and date-handling/duplicate-
  detection rules.
- The Appendix documents real observed quirks of the DDRC Agilus lab format
  (multi-date headers, inline High/Low flags, age-qualified reference ranges)
  — useful as a concrete test fixture reference.
- "Out of Scope — V1" lists deferred features (cloud sync, doctor sharing,
  ABDM integration, additional panels) — don't implement these without
  explicit user request. **One exception:** that list defers encrypted
  export/import to V1.1; it has since been pulled into V1 scope by explicit
  decision (see Standing constraints #5). The outline is stale on this point.

import 'package:flutter_test/flutter_test.dart';
import 'package:mediscan/modules/pii_stripping/row_reconstructor.dart';

import 'support/ocr_fixtures.dart';

/// Row reconstruction covers the **OCR path only**.
///
/// There are two extraction paths into PII stripping. Camera captures and
/// rasterized image-only PDFs go through ML Kit, whose blocks are organized by
/// visual column rather than by table row, so they must pass through
/// [RowReconstructor] before any regex sees them — that is what these tests
/// exercise, via `PiiStrippingService.stripFromOcr`.
///
/// Digitally generated PDFs take the text-layer path instead. Those lines
/// arrive already in reading order and go straight to
/// `PiiStrippingService.stripFromTextLines`, **bypassing this file entirely**.
/// When extraction misbehaves in the field, establish which path ran before
/// looking here.
///
/// The algorithm groups lines whose vertical centres fall within ±0.5 × the
/// **global median line height**, comparing each candidate against the running
/// average of the group so far. Several tests below pin behaviour that is
/// arguably wrong; they are marked, and they exist so a tolerance change
/// surfaces as a failing test rather than a silent change in what gets
/// extracted.
void main() {
  const line = ocrLine;
  const ocr = ocrResult;

  List<String> textsOf(List<ReconstructedRow> rows) =>
      rows.map((r) => r.text).toList();

  group('degenerate input', () {
    test('no blocks yields no rows', () {
      expect(RowReconstructor.reconstructRows(ocr([])), isEmpty);
    });

    test('blocks containing no lines yields no rows', () {
      expect(RowReconstructor.reconstructRows(ocr([[], []])), isEmpty);
    });

    test('a single block with a single line yields one row', () {
      final rows = RowReconstructor.reconstructRows(
        ocr([
          [line('HEMOGLOBIN', center: 0.5)]
        ]),
      );
      expect(rows, hasLength(1));
      expect(rows.single.text, 'HEMOGLOBIN');
      expect(rows.single.sourceLines, hasLength(1));
    });

    test('lines with zero height yield no rows at all', () {
      // The median is computed only over positive heights; when none survive
      // the reconstructor bails out. Worth knowing: a degenerate page produces
      // silence rather than an error, so an empty result is not proof that
      // OCR found nothing.
      final rows = RowReconstructor.reconstructRows(
        ocr([
          [
            line('HEMOGLOBIN', center: 0.5, height: 0),
            line('14.2', center: 0.5, height: 0, left: 0.45),
          ]
        ]),
      );
      expect(rows, isEmpty);
    });
  });

  group('column joining', () {
    test('joins per-column blocks at the same vertical position', () {
      // The reason this class exists: ML Kit returns one block per visual
      // column, so a table row arrives split across three blocks.
      final rows = RowReconstructor.reconstructRows(
        ocr([
          [line('HEMOGLOBIN', center: 0.5, left: 0.05)],
          [line('14.2', center: 0.5, left: 0.45)],
          [line('g/dL', center: 0.5, left: 0.60)],
        ]),
      );
      expect(rows, hasLength(1));
      expect(rows.single.text, 'HEMOGLOBIN\t14.2\tg/dL');
    });

    test('orders fragments left to right regardless of block order', () {
      final rows = RowReconstructor.reconstructRows(
        ocr([
          [line('g/dL', center: 0.5, left: 0.60)],
          [line('HEMOGLOBIN', center: 0.5, left: 0.05)],
          [line('14.2', center: 0.5, left: 0.45)],
        ]),
      );
      expect(rows.single.text, 'HEMOGLOBIN\t14.2\tg/dL');
    });

    test('returns vertically distinct rows in top-to-bottom order', () {
      final rows = RowReconstructor.reconstructRows(
        ocr([
          [
            line('PLATELET COUNT', center: 0.50),
            line('HEMOGLOBIN', center: 0.30),
          ],
          [
            line('250', center: 0.50, left: 0.45),
            line('14.2', center: 0.30, left: 0.45),
          ],
        ]),
      );
      expect(
        textsOf(rows),
        equals(['HEMOGLOBIN\t14.2', 'PLATELET COUNT\t250']),
      );
    });
  });

  group('tolerance band', () {
    // Two lines of height 0.02 give a median of 0.02 and a tolerance of 0.01.

    test('groups fragments just inside the band', () {
      final rows = RowReconstructor.reconstructRows(
        ocr([
          [
            line('HEMOGLOBIN', center: 0.5000),
            line('14.2', center: 0.5095, left: 0.45),
          ]
        ]),
      );
      expect(rows, hasLength(1), reason: 'centres differ by 0.0095 < 0.01');
      expect(rows.single.text, 'HEMOGLOBIN\t14.2');
    });

    test('splits fragments just outside the band', () {
      final rows = RowReconstructor.reconstructRows(
        ocr([
          [
            line('HEMOGLOBIN', center: 0.5000),
            line('14.2', center: 0.5105, left: 0.45),
          ]
        ]),
      );
      expect(rows, hasLength(2), reason: 'centres differ by 0.0105 > 0.01');
      expect(textsOf(rows), equals(['HEMOGLOBIN', '14.2']));
    });

    test(
      'KNOWN LIMITATION: a smaller-font section is over-grouped because the '
      'tolerance uses the global median',
      () {
        // Five body lines at 0.04 and four footnote lines at 0.01. The median
        // is dominated by the body text, so the tolerance (0.02) is wider than
        // the footnote's entire line spacing and the whole footnote collapses
        // into a single row.
        //
        // This matters for real reports: DDRC prints METHOD sub-lines and
        // reference-tier text in a noticeably smaller face than the results
        // table. A font-size-aware or locally-derived tolerance would change
        // this result, which is precisely why it is pinned.
        final rows = RowReconstructor.reconstructRows(
          ocr([
            [
              for (var i = 0; i < 5; i++)
                line('BODY $i', center: 0.10 + i * 0.10, height: 0.04),
              for (var i = 0; i < 4; i++)
                line('note $i', center: 0.80 + i * 0.008, height: 0.01),
            ]
          ]),
        );

        expect(rows, hasLength(6), reason: '5 body rows + 1 collapsed footnote');
        expect(
          rows.last.sourceLines,
          hasLength(4),
          reason: 'four visually separate footnote lines became one row',
        );
      },
    );

    test(
      'EDGE: at the tolerance boundary the outcome depends on how the '
      'coordinates were computed, not on their nominal values',
      () {
        // Both cases below place two footnote lines a nominal 0.02 apart —
        // exactly the tolerance — against the same five body lines. They
        // reconstruct differently.
        //
        //   literal      0.83  - 0.81 = 0.019999999999999907  <= 0.02  group
        //   accumulated  (0.80 + 3 * 0.01) - 0.81
        //                      = 0.020000000000000018  >  0.02  split
        //
        // 0.81 and 0.80 + 1 * 0.01 are the same double; 0.83 and
        // 0.80 + 3 * 0.01 are not. Since ML Kit's real coordinates arrive as
        // pixel divisions rather than round decimals, a row sitting on the
        // boundary is decided by accumulated representation error.
        //
        // Pinned so that introducing an epsilon, or switching `<=` to `<`,
        // shows up here rather than as an unexplained change in extraction.
        List<ReconstructedRow> withNoteCentres(double a, double b) =>
            RowReconstructor.reconstructRows(
              ocr([
                [
                  for (var i = 0; i < 5; i++)
                    line('BODY $i', center: 0.10 + i * 0.10, height: 0.04),
                  line('note a', center: a, height: 0.01, left: 0.05),
                  line('note b', center: b, height: 0.01, left: 0.06),
                ]
              ]),
            );

        final literal = withNoteCentres(0.81, 0.83);
        expect(literal, hasLength(6), reason: 'notes grouped');
        expect(literal.last.text, 'note a\tnote b');

        final accumulated = withNoteCentres(0.80 + 1 * 0.01, 0.80 + 3 * 0.01);
        expect(accumulated, hasLength(7), reason: 'notes did not group');
        expect(textsOf(accumulated).sublist(5), equals(['note a', 'note b']));
      },
    );
  });

  group('superscript and subscript fragments', () {
    // Units like 10³/µL and µIU/mL frequently come back as separate blocks
    // with offset baselines.

    test('keeps a superscript in its row when the baseline offset is small', () {
      final rows = RowReconstructor.reconstructRows(
        ocr([
          [
            line('WBC COUNT', center: 0.500, left: 0.05),
            line('8.4', center: 0.500, left: 0.45),
            line('10', center: 0.500, left: 0.600, width: 0.03),
            line('3', center: 0.495, height: 0.01, left: 0.635, width: 0.01),
            line('/µL', center: 0.500, left: 0.650, width: 0.04),
          ]
        ]),
      );
      expect(rows, hasLength(1));
      expect(rows.single.text, 'WBC COUNT\t8.4\t10\t3\t/µL');
    });

    test(
      'KNOWN LIMITATION: a superscript raised past the tolerance orphans '
      'itself and silently mangles the unit',
      () {
        // The exponent lands in its own row, which the allowlist will reject.
        // The parameter row survives but now reads "10 /µL" — a unit that is
        // wrong rather than absent, so nothing downstream flags it.
        final rows = RowReconstructor.reconstructRows(
          ocr([
            [
              line('WBC COUNT', center: 0.500, left: 0.05),
              line('8.4', center: 0.500, left: 0.45),
              line('10', center: 0.500, left: 0.600, width: 0.03),
              line('3', center: 0.486, height: 0.01, left: 0.635, width: 0.01),
              line('/µL', center: 0.500, left: 0.650, width: 0.04),
            ]
          ]),
        );
        expect(rows, hasLength(2));
        expect(rows.first.text, '3');
        expect(rows.last.text, 'WBC COUNT\t8.4\t10\t/µL');
      },
    );
  });

  group('DDRC METHOD sub-lines', () {
    test('stay out of the parameter row', () {
      // DDRC prints "METHOD : ..." directly beneath each parameter in a
      // smaller face. At the current tolerance they form their own rows and
      // are rejected by the allowlist, which is the outcome we want. Loosening
      // the tolerance would merge them into the parameter row and corrupt the
      // extracted value — this test is the tripwire for that.
      final rows = RowReconstructor.reconstructRows(
        ocr([
          [
            line('HBA1C', center: 0.30),
            line('6.2', center: 0.30, left: 0.45),
            line('METHOD : HPLC', center: 0.33, height: 0.012),
            line('CHOLESTEROL, TOTAL', center: 0.40),
            line('185', center: 0.40, left: 0.45),
            line('METHOD : CHOD-PAP', center: 0.43, height: 0.012),
            line('HEMOGLOBIN', center: 0.50),
            line('14.2', center: 0.50, left: 0.45),
            line('METHOD : PHOTOMETRY', center: 0.53, height: 0.012),
          ]
        ]),
      );

      expect(
        textsOf(rows),
        equals([
          'HBA1C\t6.2',
          'METHOD : HPLC',
          'CHOLESTEROL, TOTAL\t185',
          'METHOD : CHOD-PAP',
          'HEMOGLOBIN\t14.2',
          'METHOD : PHOTOMETRY',
        ]),
      );

      for (final row in rows.where((r) => r.text.contains('METHOD'))) {
        expect(
          row.sourceLines,
          hasLength(1),
          reason: 'a METHOD line must never absorb a parameter fragment',
        );
      }
    });
  });

  group('multi-line reference blocks', () {
    test('the value stays attached to the parameter name', () {
      // HbA1c prints one value beside five stacked reference tiers. Only the
      // first tier shares the parameter's baseline; the rest must not pull the
      // value away from its name.
      const tiers = [
        'Non-diabetic : <5.7',
        'Prediabetic : 5.7-6.4',
        'Diabetic : >6.4',
        'Target : <7.0',
        'Action : >8.0',
      ];
      final rows = RowReconstructor.reconstructRows(
        ocr([
          [
            line('HBA1C', center: 0.50, left: 0.05),
            line('6.2', center: 0.50, left: 0.45, width: 0.05),
            line('%', center: 0.50, left: 0.55, width: 0.02),
          ],
          [
            for (var i = 0; i < tiers.length; i++)
              line(
                tiers[i],
                center: 0.50 + i * 0.03,
                height: 0.015,
                left: 0.70,
                width: 0.25,
              ),
          ],
        ]),
      );

      expect(rows, hasLength(5));
      expect(rows.first.text, 'HBA1C\t6.2\t%\t${tiers.first}');

      final valueRows = rows.where((r) => r.text.contains('6.2')).toList();
      expect(
        valueRows,
        hasLength(1),
        reason: 'the value must appear in exactly one row',
      );
      expect(valueRows.single.text, startsWith('HBA1C'));
    });
  });

  group('wrapped parameter names', () {
    // The DDRC sample contains "MEAN CORPUSCULAR HEMOGLOBIN CONCENTRATION
    // (MCHC)" wrapped across two lines in the name column.

    test('a value aligned with the first line keeps that fragment only', () {
      final rows = RowReconstructor.reconstructRows(
        ocr([
          [
            line('MEAN CORPUSCULAR HEMOGLOBIN', center: 0.500, left: 0.05),
            line('CONCENTRATION (MCHC)', center: 0.525, left: 0.05),
            line('33.5', center: 0.500, left: 0.45),
          ]
        ]),
      );

      // The wrapped tail becomes its own row, so normalization sees a
      // truncated name. Token-overlap matching has to cope with that.
      expect(
        textsOf(rows),
        equals([
          'MEAN CORPUSCULAR HEMOGLOBIN\t33.5',
          'CONCENTRATION (MCHC)',
        ]),
      );
    });

    test(
      'KNOWN LIMITATION: a value centred against a wrapped name is lost '
      'entirely',
      () {
        // When the lab centres the value against the two-line name rather than
        // aligning it with the first line, every fragment lands more than the
        // tolerance from its neighbours. The value ends up alone in a row
        // containing nothing else, which the allowlist rejects as a bare
        // number — the reading disappears with no warning.
        final rows = RowReconstructor.reconstructRows(
          ocr([
            [
              line('MEAN CORPUSCULAR HEMOGLOBIN', center: 0.5000, left: 0.05),
              line('CONCENTRATION (MCHC)', center: 0.5250, left: 0.05),
              line('33.5', center: 0.5125, left: 0.45),
            ]
          ]),
        );

        expect(rows, hasLength(3));
        expect(
          textsOf(rows),
          equals([
            'MEAN CORPUSCULAR HEMOGLOBIN',
            '33.5',
            'CONCENTRATION (MCHC)',
          ]),
        );
      },
    );
  });

  group('row metadata', () {
    test('the bounding box spans every fragment in the row', () {
      // PositionClassifier keys off these values, so a row that under-reports
      // its extent can be classified into the wrong zone and discarded.
      // The tallest fragment sets the top edge and a different one sets the
      // bottom, so neither edge can be produced by reading a single line's box.
      final rows = RowReconstructor.reconstructRows(
        ocr([
          [
            line('HEMOGLOBIN', center: 0.500, height: 0.030, left: 0.05),
            line('14.2', center: 0.504, height: 0.010, left: 0.45),
            line('g/dL', center: 0.508, height: 0.020, left: 0.60),
          ]
        ]),
      );

      expect(rows, hasLength(1));
      expect(rows.single.text, 'HEMOGLOBIN\t14.2\tg/dL');
      expect(
        rows.single.normalizedTop,
        closeTo(0.485, 1e-9),
        reason: 'top edge comes from the name fragment',
      );
      expect(
        rows.single.normalizedBottom,
        closeTo(0.518, 1e-9),
        reason: 'bottom edge comes from the unit fragment',
      );
    });

    test('sourceLines cannot be mutated by callers', () {
      final rows = RowReconstructor.reconstructRows(
        ocr([
          [line('HEMOGLOBIN', center: 0.5)]
        ]),
      );
      expect(
        () => rows.single.sourceLines.add(line('x', center: 0.5)),
        throwsUnsupportedError,
      );
    });
  });
}

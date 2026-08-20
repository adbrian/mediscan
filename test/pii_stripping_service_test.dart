import 'package:flutter_test/flutter_test.dart';
import 'package:mediscan/modules/pii_stripping/pii_stripping_service.dart';
import 'package:mediscan/modules/pii_stripping/position_classifier.dart';
import 'package:mediscan/modules/pii_stripping/regex_rules.dart';

import 'support/ocr_fixtures.dart';

/// PII stripping is the privacy checkpoint: the last thing that runs before
/// anything is eligible for storage. It has two entry points, and which one
/// ran is the first question to ask when extraction misbehaves.
///
/// * [PiiStrippingService.stripFromOcr] — the **OCR path**. Camera captures
///   and rasterized image-only PDFs. Rows are reconstructed from ML Kit blocks
///   first, then classified by page zone *and* by content.
/// * [PiiStrippingService.stripFromTextLines] — the **text-layer path**.
///   Digitally generated PDFs. No bounding boxes exist, so content rules are
///   the only defense; the positional zone filter does not run at all.
///
/// The invariant both paths share is fail-closed: the default action for any
/// line is discard, and a line is retained only on a positive match against a
/// retain pattern. The discard regexes are a secondary defense. Tests that
/// assert `isRetained` is false on unmatched input are guarding that
/// invariant, not merely describing today's behaviour.
void main() {
  final service = PiiStrippingService();

  /// Lines that must never be retained by either path.
  const piiCorpus = <String>[
    'Patient Name : MR RAJESH KUMAR',
    'Name : SUNITA DEVI',
    '39 Yrs / Male',
    '25 Years / F',
    'Sex : Female',
    'Gender : Male',
    'UHID : 4471203',
    'ACCESSION NO : DD24-889201',
    'ABHA NO : 12-3456-7890-1234',
    'Registration No : 99201',
    'Patient ID : P-88213',
    'Mobile : 9876543210',
    'rajesh.kumar@example.com',
    'Kochi, Kerala 682024',
    'Ref By : DR. S MENON',
    'Referred By : DR ANIL VARMA',
    'Consultant : DR. PRIYA NAIR',
    '42/1965, MG Road, Ernakulam',
    'Flat 3B, Sunrise Nagar, Kakkanad',
    'Patient Ref : OPD-2291',
  ];

  /// Results lines that must survive both paths.
  const resultsCorpus = <String>[
    'HEMOGLOBIN\t14.2\tg/dL',
    'CHOLESTEROL, TOTAL\t185\tmg/dL',
    'HBA1C\t6.2\t%',
    'WBC COUNT\t8.4\t10^3/uL',
    'TSH\t2.10\tmIU/L',
    'SGPT (ALT)\t28\tU/L',
    'VITAMIN D\t22.4\tng/mL',
    'MCV\t88.2\tfL',
    'SYSTOLIC BP\t120\tmmHg',
    'TRIGLYCERIDES\t142\tmg/dL',
  ];

  /// Lines matching neither a retain nor a discard rule.
  const unclassifiedCorpus = <String>[
    'DEPARTMENT OF BIOCHEMISTRY',
    'METHOD : HPLC',
    'SAMPLE TYPE : SERUM',
    '*** End of Report ***',
    'Page 1 of 17',
  ];

  group('fail-closed default (the core invariant)', () {
    test('every unclassified line is withheld, not retained', () {
      for (final text in unclassifiedCorpus) {
        final result = service.stripFromTextLines([text]).single;
        expect(
          result.isRetained,
          isFalse,
          reason: 'unmatched line was retained: "$text"',
        );
        expect(result.isAmbiguous, isTrue, reason: text);
      }
    });

    test('ambiguous lines are flagged but still not retained', () {
      // The service passes ambiguous lines through for normalization to
      // attempt, so a caller that reads the list without filtering on
      // isRetained would leak exactly the text the allowlist declined to
      // vouch for. isRetained is the gate; isAmbiguous is only a hint.
      final ambiguous = service
          .stripFromTextLines(unclassifiedCorpus)
          .where((l) => l.isAmbiguous);

      expect(ambiguous, isNotEmpty);
      expect(ambiguous.every((l) => !l.isRetained), isTrue);
    });

    test('blank and whitespace-only lines are withheld without being flagged', () {
      for (final blank in ['', '   ', '\t', '\n  \t ']) {
        final result = service.stripFromTextLines([blank]).single;
        expect(result.isRetained, isFalse);
        expect(
          result.isAmbiguous,
          isFalse,
          reason: 'empty input is not worth flagging for review',
        );
        expect(result.text, isEmpty);
      }
    });

    test('no line in the PII corpus survives the text-layer path', () {
      for (final text in piiCorpus) {
        expect(
          service.stripFromTextLines([text]).single.isRetained,
          isFalse,
          reason: 'PII was retained: "$text"',
        );
      }
    });
  });

  group('retain: parameter-value-unit', () {
    test('every line in the results corpus is retained', () {
      for (final text in resultsCorpus) {
        final result = service.stripFromTextLines([text]).single;
        expect(result.isRetained, isTrue, reason: 'dropped: "$text"');
        expect(result.detectedDate, isNull);
      }
    });

    test('retained lines keep their text verbatim after trimming', () {
      final result =
          service.stripFromTextLines(['  HEMOGLOBIN\t14.2\tg/dL  ']).single;
      expect(result.text, 'HEMOGLOBIN\t14.2\tg/dL');
    });

    test(
      'KNOWN LIMITATION: a two-character parameter name is silently dropped',
      () {
        // The retain regex is `[A-Za-z]` followed by 2–40 more name
        // characters, then whitespace, then the value. A two-letter name
        // leaves only one character before the separator, so the pattern
        // cannot match and the row is discarded as unclassified.
        //
        // This is not hypothetical: Hb, TG and TC are all listed in the
        // variant dictionary in parameter_definitions.dart, so any lab
        // printing those short forms loses those readings before
        // normalization ever sees them. RowReconstructor joins fragments with
        // a single tab, which is exactly the failing shape.
        for (final text in ['Hb\t14.2\tg/dL', 'TG\t150\tmg/dL', 'TC\t185\tmg/dL']) {
          expect(
            service.stripFromTextLines([text]).single.isRetained,
            isFalse,
            reason: 'expected the known drop for "$text"',
          );
        }

        // Three characters is enough, which is why HDL and LDL survive.
        expect(
          service.stripFromTextLines(['HDL\t45\tmg/dL']).single.isRetained,
          isTrue,
        );

        // And the same two-letter name matches when two spaces separate it
        // from the value, which pins the mechanism as the separator width
        // rather than the name itself.
        expect(
          service.stripFromTextLines(['TG  150 mg/dL']).single.isRetained,
          isTrue,
        );
      },
    );
  });

  group('retain: collection date', () {
    test('recognises the collection-date phrasings labs actually print', () {
      const dates = {
        'Collected On: 27/06/2026': '27/06/2026',
        'DRAWN :27/06/2026 08:02:50': '27/06/2026',
        'Sample Date: 15-03-2025': '15-03-2025',
        'Reported On : 28.06.2026': '28.06.2026',
        'Collection Date : 1/7/26': '1/7/26',
      };

      dates.forEach((text, expected) {
        final result = service.stripFromTextLines([text]).single;
        expect(result.isRetained, isTrue, reason: text);
        expect(result.detectedDate, expected, reason: text);
      });
    });

    test('a results line carries no detectedDate', () {
      final result =
          service.stripFromTextLines(['HEMOGLOBIN\t14.2\tg/dL']).single;
      expect(result.isRetained, isTrue);
      expect(result.detectedDate, isNull);
    });

    test('a bare date with no collection keyword is not retained', () {
      // Report footers carry print timestamps and accreditation dates. Only
      // a date introduced by a collection keyword is trustworthy as
      // test_date, so a naked date must fall through to unclassified.
      final result = service.stripFromTextLines(['27/06/2026']).single;
      expect(result.isRetained, isFalse);
      expect(result.detectedDate, isNull);
    });
  });

  group('discard patterns (secondary defense)', () {
    test('each rule fires on the line shape it exists for', () {
      const cases = <String, String>{
        'Patient Name : MR RAJESH KUMAR': 'patient name',
        '39 Yrs / Male': 'age and gender',
        'Sex : Female': 'gender label',
        'UHID : 4471203': 'identifier',
        'ACCESSION NO : DD24-889201': 'accession number',
        'ABHA NO : 12-3456-7890-1234': 'ABHA number',
        'Mobile : 9876543210': 'phone number',
        'rajesh.kumar@example.com': 'email',
        'Kochi, Kerala 682024': 'PIN code',
        'Ref By : DR. S MENON': 'doctor reference',
        '42/1965, MG Road, Ernakulam': 'address token',
        'Patient Ref : OPD-2291': 'patient reference',
      };

      cases.forEach((text, description) {
        expect(
          RegexRules.matchesAnyDiscard(text),
          isTrue,
          reason: 'no discard rule matched $description: "$text"',
        );
      });
    });

    test(
      'KNOWN GAP: age and gender without a separator matches no discard rule',
      () {
        // RegexRules.ageGender documents "39 Years Male" as a match, but the
        // pattern requires a slash or backslash between the age and the sex.
        // The unseparated form reaches the classifier unmatched.
        //
        // Fail-closed still withholds it, so this is a documentation defect
        // rather than a leak — but the discard rule is not doing the job its
        // comment claims, and a future change that starts trusting the
        // blocklist would inherit the hole.
        expect(RegexRules.ageGender.hasMatch('39 Years Male'), isFalse);
        expect(RegexRules.matchesAnyDiscard('39 Years Male'), isFalse);

        final result = service.stripFromTextLines(['39 Years Male']).single;
        expect(
          result.isRetained,
          isFalse,
          reason: 'the fail-closed default is what withholds this, not a rule',
        );
        expect(result.isAmbiguous, isTrue);
      },
    );
  });

  group('classification precedence', () {
    test('retain is evaluated before discard, and that ordering is load-bearing',
        () {
      // A six-digit platelet count trips the PIN-code discard rule. Because
      // the allowlist is consulted first, the reading survives. Reversing the
      // order would silently drop every six-digit result value.
      const line = 'PLATELET COUNT\t250000\tcells/uL';

      expect(
        RegexRules.matchesAnyDiscard(line),
        isTrue,
        reason: 'the PIN-code rule does match this line',
      );
      expect(RegexRules.matchesRetain(line), isTrue);
      expect(service.stripFromTextLines([line]).single.isRetained, isTrue);
    });

    test('collection date is evaluated before everything else', () {
      // A date line that also trips a discard rule is still retained, because
      // test_date is the one field the pipeline cannot proceed without.
      const line = 'Sample Collected On: 27/06/2026 at Kakkanad Road';
      expect(RegexRules.matchesAnyDiscard(line), isTrue);

      final result = service.stripFromTextLines([line]).single;
      expect(result.isRetained, isTrue);
      expect(result.detectedDate, '27/06/2026');
    });
  });

  group('OCR path: positional zones', () {
    test('header content is discarded even when it is not recognisably PII', () {
      final rows = service.stripFromOcr(
        ocrResult([
          [ocrLine('DDRC AGILUS PATHLABS', center: 0.05)],
          [ocrLine('Patient Name : RAJESH KUMAR', center: 0.12)],
        ]),
      );
      expect(rows, isEmpty, reason: 'the header zone yields nothing at all');
    });

    test('footer content is discarded', () {
      final rows = service.stripFromOcr(
        ocrResult([
          [ocrLine('Authorised Signatory', center: 0.90)],
          [ocrLine('This is a computer generated report', center: 0.95)],
        ]),
      );
      expect(rows, isEmpty);
    });

    test('a collection date in the header survives the zone filter', () {
      // The documented exception, and the reason it exists: DDRC prints
      // "DRAWN :" in the header band, and test_date is not recoverable from
      // anywhere else on the page.
      final rows = service.stripFromOcr(
        ocrResult([
          [ocrLine('Patient Name : RAJESH KUMAR', center: 0.10)],
          [ocrLine('DRAWN :27/06/2026 08:02:50', center: 0.15)],
        ]),
      );

      expect(rows, hasLength(1));
      expect(rows.single.isRetained, isTrue);
      expect(rows.single.detectedDate, '27/06/2026');
    });

    test('a collection date in the footer survives too', () {
      final rows = service.stripFromOcr(
        ocrResult([
          [ocrLine('Reported On : 28.06.2026', center: 0.92)],
        ]),
      );
      expect(rows.single.detectedDate, '28.06.2026');
    });

    test(
      'a genuine reading placed in the header zone is discarded anyway',
      () {
        // Position beats content in the header and footer bands: only the
        // collection-date exception is consulted there. A results table that
        // starts unusually high on the page loses its top rows, and nothing
        // reports that it happened.
        final rows = service.stripFromOcr(
          ocrResult([
            [ocrLine('HEMOGLOBIN\t14.2\tg/dL', center: 0.15)],
          ]),
        );
        expect(rows, isEmpty);
      },
    );

    test('content-zone rows are classified by content rules', () {
      final rows = service.stripFromOcr(
        ocrResult([
          [
            ocrLine('HEMOGLOBIN', center: 0.40, left: 0.05),
            ocrLine('Ref By : DR MENON', center: 0.50, left: 0.05),
            ocrLine('DEPARTMENT OF HAEMATOLOGY', center: 0.60, left: 0.05),
          ],
          [
            ocrLine('14.2', center: 0.40, left: 0.45),
            ocrLine('g/dL', center: 0.40, left: 0.60),
          ],
        ]),
      );

      expect(rows, hasLength(3));
      expect(rows[0].text, 'HEMOGLOBIN\t14.2\tg/dL');
      expect(rows[0].isRetained, isTrue);
      expect(rows[1].isRetained, isFalse, reason: 'doctor reference');
      expect(rows[2].isRetained, isFalse, reason: 'unclassified');
      expect(rows[2].isAmbiguous, isTrue);
    });

    test('zone boundaries fall where PositionClassifier says they do', () {
      expect(PositionClassifier.classify(0.20, 0.20), PositionZone.header);
      expect(PositionClassifier.classify(0.20, 0.22), PositionZone.content);
      expect(PositionClassifier.classify(0.84, 0.84), PositionZone.content);
      expect(PositionClassifier.classify(0.85, 0.85), PositionZone.footer);
      expect(PositionClassifier.classify(0.0, 0.0), PositionZone.header);
      expect(PositionClassifier.classify(1.0, 1.0), PositionZone.footer);
    });

    test('an empty OcrResult yields no lines', () {
      expect(service.stripFromOcr(ocrResult([])), isEmpty);
    });
  });

  group('text-layer path', () {
    test('returns exactly one result per input line, in order', () {
      final input = [...resultsCorpus, ...piiCorpus];
      final results = service.stripFromTextLines(input);

      expect(results, hasLength(input.length));
      expect(
        results.take(resultsCorpus.length).every((r) => r.isRetained),
        isTrue,
      );
      expect(
        results.skip(resultsCorpus.length).every((r) => !r.isRetained),
        isTrue,
      );
    });

    test('blank lines are preserved as positions rather than dropped', () {
      final results = service.stripFromTextLines(
        ['HEMOGLOBIN\t14.2\tg/dL', '', 'HBA1C\t6.2\t%'],
      );
      expect(results, hasLength(3));
      expect(results[1].text, isEmpty);
      expect(results[1].isRetained, isFalse);
    });

    test('content rules are the only defense on this path', () {
      // The same header PII that the OCR path would discard on position has
      // to be caught by a content rule here, because no bounding boxes exist.
      const header = 'Patient Name : RAJESH KUMAR';
      expect(RegexRules.matchesAnyDiscard(header), isTrue);
      expect(service.stripFromTextLines([header]).single.isRetained, isFalse);
    });
  });

  group('cross-path consistency', () {
    test('a content-zone row classifies identically on both paths', () {
      const text = 'HEMOGLOBIN\t14.2\tg/dL';

      final viaText = service.stripFromTextLines([text]).single;
      final viaOcr = service
          .stripFromOcr(ocrResult([
            [ocrLine(text, center: 0.50)]
          ]))
          .single;

      expect(viaOcr.text, viaText.text);
      expect(viaOcr.isRetained, viaText.isRetained);
      expect(viaOcr.isAmbiguous, viaText.isAmbiguous);
      expect(viaOcr.detectedDate, viaText.detectedDate);
    });

    test(
      'the paths diverge in the header band, by design',
      () {
        // Same text, same content rules, different answer — because only the
        // OCR path knows where on the page the line sat. Worth pinning: it is
        // the clearest reason to establish which path ran before debugging a
        // missing reading.
        const text = 'HEMOGLOBIN\t14.2\tg/dL';

        expect(service.stripFromTextLines([text]).single.isRetained, isTrue);
        expect(
          service.stripFromOcr(ocrResult([
            [ocrLine(text, center: 0.10)]
          ])),
          isEmpty,
        );
      },
    );
  });
}

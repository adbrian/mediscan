import 'package:flutter_test/flutter_test.dart';
import 'package:mediscan/core/constants/parameter_definitions.dart';
import 'package:mediscan/core/database/database_service.dart';
import 'package:mediscan/core/models/parameter.dart';
import 'package:mediscan/core/models/reading.dart';
import 'package:mediscan/core/models/report.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Storage-layer tests, run against an unencrypted in-memory SQLite database
/// through [DatabaseService.withOpener].
///
/// **Encryption is not covered here.** The injected opener replaces the
/// SQLCipher call entirely, so these tests verify schema, queries, and
/// transaction behaviour — not that data at rest is encrypted, and not that
/// the key survives biometric re-enrollment. Both need a physical device and
/// remain unverified.
///
/// The chronology group is the one that guards a standing constraint:
/// `test_date` is the sole source of truth for ordering, never `scan_date`,
/// `created_at`, or insertion order.
void main() {
  sqfliteFfiInit();

  /// Records what the service passed down, so the key wiring is checkable even
  /// though the SQLCipher call itself is substituted out.
  String? capturedPassword;
  String? capturedPath;

  Future<Database> ffiOpener(
    String path, {
    required String password,
    required int version,
    required OnDatabaseCreateFn onCreate,
  }) {
    capturedPassword = password;
    capturedPath = path;
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: version, onCreate: onCreate),
    );
  }

  late DatabaseService db;

  setUp(() {
    capturedPassword = null;
    capturedPath = null;
    db = DatabaseService.withOpener(ffiOpener);
  });

  tearDown(() => db.close());

  Future<int> paramId(String canonicalName) async =>
      (await db.getParameterByCanonicalName(canonicalName))!.id!;

  /// Inserts a report whose readings are `(parameterId, value)` pairs.
  Future<int> insertReport({
    required String testDate,
    required List<(int, double)> readings,
    String scanDate = '2026-08-01',
    String? labName,
    String entryType = 'scan',
  }) =>
      db.insertReport(
        Report(scanDate: scanDate, testDate: testDate, labName: labName),
        [
          for (final (parameterId, value) in readings)
            Reading(
              reportId: 0,
              parameterId: parameterId,
              value: value,
              unit: 'mg/dL',
              entryType: entryType,
              createdAt: '2026-08-01T09:00:00Z',
            ),
        ],
      );

  group('schema and seeding', () {
    test('seeds every canonical parameter exactly once', () async {
      final parameters = await db.getParameters();

      expect(
        parameters,
        hasLength(ParameterDefinitions.canonicalParameters.length),
      );
      expect(
        parameters.map((p) => p.canonicalName).toSet(),
        equals(
          ParameterDefinitions.canonicalParameters
              .map((d) => d['canonicalName'] as String)
              .toSet(),
        ),
      );
      expect(parameters.every((p) => !p.isCustom), isTrue);
    });

    test('seeded parameters carry their reference ranges', () async {
      final hba1c = await db.getParameterByCanonicalName('hba1c');

      expect(hba1c, isNotNull);
      expect(hba1c!.displayName, 'HbA1c');
      expect(hba1c.defaultUnit, '%');
      expect(hba1c.refLow, 4.0);
      expect(hba1c.refHigh, 5.6);
      expect(hba1c.panel, 'blood_sugar');
    });

    test('open-ended reference ranges keep their null bound', () async {
      // "<200" has no lower bound. A zero here instead of null would make
      // every low cholesterol reading register as in-range against 0.
      final cholesterol =
          await db.getParameterByCanonicalName('total_cholesterol');
      expect(cholesterol!.refLow, isNull);
      expect(cholesterol.refHigh, 200.0);
    });

    test('getParameterByCanonicalName returns null for an unknown name', () async {
      expect(await db.getParameterByCanonicalName('not_a_parameter'), isNull);
    });

    test('forwards the resolved path and key to the opener', () async {
      await db.getParameters();

      // Proves _initDatabase resolves both and passes them down. It does NOT
      // prove SQLCipher is applied — the opener under test is not the
      // production one, so `_openWithSqlCipher` remains unexercised.
      expect(capturedPassword, 'test-encryption-key');
      expect(capturedPath, ':memory:');
    });
  });

  group('reports and readings', () {
    test('insertReport writes the report and its readings together', () async {
      final glucose = await paramId('fasting_glucose');
      final hba1c = await paramId('hba1c');

      final reportId = await insertReport(
        testDate: '2026-06-27',
        labName: 'DDRC Agilus',
        readings: [(glucose, 92.0), (hba1c, 5.4)],
      );

      final report = await db.getReportById(reportId);
      expect(report!.testDate, '2026-06-27');
      expect(report.labName, 'DDRC Agilus');

      final readings = await db.getReadingsForReport(reportId);
      expect(readings, hasLength(2));
      expect(readings.map((r) => r.value), containsAll([92.0, 5.4]));
    });

    test('stamps every reading with the new report id', () async {
      final glucose = await paramId('fasting_glucose');
      final reportId = await insertReport(
        testDate: '2026-06-27',
        readings: [(glucose, 92.0), (glucose, 93.0)],
      );

      final readings = await db.getReadingsForReport(reportId);
      expect(readings.every((r) => r.reportId == reportId), isTrue);
    });

    test('discards a client-supplied reading id', () async {
      final glucose = await paramId('fasting_glucose');

      final reportId = await db.insertReport(
        const Report(scanDate: '2026-08-01', testDate: '2026-06-27'),
        [
          Reading(
            id: 999,
            reportId: 0,
            parameterId: glucose,
            value: 92.0,
            unit: 'mg/dL',
            createdAt: '2026-08-01T09:00:00Z',
          ),
        ],
      );

      final readings = await db.getReadingsForReport(reportId);
      expect(
        readings.single.id,
        isNot(999),
        reason: 'the database assigns ids, not the caller',
      );
    });

    test('getReportById returns null for an unknown id', () async {
      expect(await db.getReportById(4242), isNull);
    });

    test('getReports is ordered by test_date descending', () async {
      final glucose = await paramId('fasting_glucose');

      // Inserted deliberately out of order. ISO-8601 dates sort
      // lexicographically, which is why TEXT ordering is chronological.
      await insertReport(testDate: '2025-01-15', readings: [(glucose, 88.0)]);
      await insertReport(testDate: '2026-06-27', readings: [(glucose, 92.0)]);
      await insertReport(testDate: '2024-03-02', readings: [(glucose, 95.0)]);

      final reports = await db.getReports();
      expect(
        reports.map((r) => r.testDate),
        equals(['2026-06-27', '2025-01-15', '2024-03-02']),
      );
    });

    test('deleteReport removes the report and its readings', () async {
      final glucose = await paramId('fasting_glucose');
      final reportId = await insertReport(
        testDate: '2026-06-27',
        readings: [(glucose, 92.0), (glucose, 93.0)],
      );

      await db.deleteReport(reportId);

      expect(await db.getReportById(reportId), isNull);
      expect(await db.getReadingsForReport(reportId), isEmpty);
    });

    test('deleteReport leaves other reports intact', () async {
      final glucose = await paramId('fasting_glucose');
      final doomed =
          await insertReport(testDate: '2026-06-27', readings: [(glucose, 92.0)]);
      final keeper =
          await insertReport(testDate: '2025-01-15', readings: [(glucose, 88.0)]);

      await db.deleteReport(doomed);

      expect(await db.getReportById(keeper), isNotNull);
      expect(await db.getReadingsForReport(keeper), hasLength(1));
    });
  });

  group('chronology is keyed on test_date', () {
    test('getReadingsForParameter sorts by test_date, not insertion order',
        () async {
      final glucose = await paramId('fasting_glucose');

      await insertReport(testDate: '2026-06-27', readings: [(glucose, 92.0)]);
      await insertReport(testDate: '2024-03-02', readings: [(glucose, 95.0)]);
      await insertReport(testDate: '2025-01-15', readings: [(glucose, 88.0)]);

      final readings = await db.getReadingsForParameter(glucose);
      expect(
        readings.map((r) => r.value),
        equals([95.0, 88.0, 92.0]),
        reason: 'ascending by test_date: 2024, 2025, 2026',
      );
    });

    test('getLatestReading uses max(test_date), not the most recent insert',
        () async {
      // The constraint this guards: users scan old reports after new ones.
      // An implementation keyed on insertion order or created_at would return
      // 88.0 here and quietly show a stale value as current.
      final glucose = await paramId('fasting_glucose');

      await insertReport(testDate: '2026-06-27', readings: [(glucose, 92.0)]);
      await insertReport(testDate: '2025-01-15', readings: [(glucose, 88.0)]);

      final latest = await db.getLatestReading(glucose);
      expect(latest!.value, 92.0);
    });

    test('scan_date has no influence on which reading is latest', () async {
      final glucose = await paramId('fasting_glucose');

      // The older specimen was scanned most recently.
      await insertReport(
        testDate: '2026-06-27',
        scanDate: '2026-07-01',
        readings: [(glucose, 92.0)],
      );
      await insertReport(
        testDate: '2025-01-15',
        scanDate: '2026-08-20',
        readings: [(glucose, 88.0)],
      );

      expect((await db.getLatestReading(glucose))!.value, 92.0);
    });

    test('getLatestReading returns null when the parameter has no readings',
        () async {
      expect(await db.getLatestReading(await paramId('hba1c')), isNull);
    });

    test('getDashboardData returns each parameter at its own latest date',
        () async {
      final glucose = await paramId('fasting_glucose');
      final hba1c = await paramId('hba1c');

      await insertReport(
        testDate: '2024-03-02',
        readings: [(glucose, 95.0), (hba1c, 6.4)],
      );
      await insertReport(testDate: '2026-06-27', readings: [(glucose, 92.0)]);

      final rows = await db.getDashboardData();
      final byName = {
        for (final row in rows) row['canonical_name'] as String: row,
      };

      expect(byName, hasLength(2));
      expect(byName['fasting_glucose']!['value'], 92.0);
      expect(byName['fasting_glucose']!['test_date'], '2026-06-27');

      // hba1c has no later reading, so its 2024 value is still current.
      expect(byName['hba1c']!['value'], 6.4);
      expect(byName['hba1c']!['test_date'], '2024-03-02');
    });

    test('getDashboardData joins the display columns the UI needs', () async {
      final glucose = await paramId('fasting_glucose');
      await insertReport(testDate: '2026-06-27', readings: [(glucose, 92.0)]);

      final row = (await db.getDashboardData()).single;
      expect(row['display_name'], 'Fasting Blood Sugar');
      expect(row['default_unit'], 'mg/dL');
      expect(row['panel'], 'blood_sugar');
      expect(row['test_date'], '2026-06-27');
    });

    test(
      'KNOWN LIMITATION: two reports sharing the latest test_date list the '
      'parameter twice',
      () async {
        // The dashboard query selects every reading whose report matches
        // max(test_date) for that parameter. Two reports on the same day —
        // a split panel, or a re-scan the user did not recognise as a
        // duplicate — therefore yield two dashboard rows for one parameter.
        //
        // findDuplicateReport is what is meant to stop this reaching the
        // database, but nothing calls it yet, and it only fires at ≥50%
        // parameter overlap. Pinned rather than fixed: the right repair is a
        // tie-break in the query, which is a Phase 5 decision.
        final glucose = await paramId('fasting_glucose');
        await insertReport(testDate: '2026-06-27', readings: [(glucose, 92.0)]);
        await insertReport(testDate: '2026-06-27', readings: [(glucose, 97.0)]);

        final rows = await db.getDashboardData();
        expect(rows, hasLength(2));
        expect(
          rows.map((r) => r['canonical_name']).toSet(),
          equals({'fasting_glucose'}),
        );
      },
    );
  });

  group('findDuplicateReport', () {
    late int glucose;
    late int hba1c;
    late int cholesterol;
    late int triglycerides;
    late int hdl;

    setUp(() async {
      glucose = await paramId('fasting_glucose');
      hba1c = await paramId('hba1c');
      cholesterol = await paramId('total_cholesterol');
      triglycerides = await paramId('triglycerides');
      hdl = await paramId('hdl_cholesterol');

      await insertReport(
        testDate: '2026-06-27',
        readings: [(glucose, 92.0), (hba1c, 5.4), (cholesterol, 185.0)],
      );
    });

    test('returns null when no report shares the test date', () async {
      expect(
        await db.findDuplicateReport('2026-06-28', [glucose, hba1c]),
        isNull,
      );
    });

    test('returns null for an empty parameter list', () async {
      expect(await db.findDuplicateReport('2026-06-27', []), isNull);
    });

    test('flags a re-scan of the same panel', () async {
      final duplicate = await db.findDuplicateReport(
        '2026-06-27',
        [glucose, hba1c, cholesterol],
      );
      expect(duplicate, isNotNull);
      expect(duplicate!.testDate, '2026-06-27');
    });

    test('flags at exactly the 50% boundary', () async {
      // Four incoming parameters, two of them already present.
      // Threshold is ceil(4 / 2) = 2, so this is a duplicate.
      final duplicate = await db.findDuplicateReport(
        '2026-06-27',
        [glucose, hba1c, triglycerides, hdl],
      );
      expect(duplicate, isNotNull);
    });

    test('does not flag one parameter below the boundary', () async {
      final duplicate = await db.findDuplicateReport(
        '2026-06-27',
        [glucose, triglycerides, hdl, await paramId('vldl_cholesterol')],
      );
      expect(duplicate, isNull, reason: 'overlap of 1 is below ceil(4 / 2)');
    });

    test('rounds the threshold up for odd parameter counts', () async {
      // Three incoming, threshold ceil(3 / 2) = 2.
      expect(
        await db.findDuplicateReport('2026-06-27', [glucose, triglycerides, hdl]),
        isNull,
        reason: 'overlap of 1 is below 2',
      );
      expect(
        await db.findDuplicateReport('2026-06-27', [glucose, hba1c, hdl]),
        isNotNull,
        reason: 'overlap of 2 meets the threshold',
      );
    });
  });

  group('custom parameters', () {
    test('insertCustomParameter stores it flagged as custom', () async {
      final id = await db.insertCustomParameter(
        const Parameter(
          canonicalName: 'eosinophils_percent',
          displayName: 'Eosinophils %',
          defaultUnit: '%',
          refLow: 1.0,
          refHigh: 6.0,
          panel: 'custom',
        ),
      );

      final stored = await db.getParameterByCanonicalName('eosinophils_percent');
      expect(stored!.id, id);
      expect(stored.isCustom, isTrue);
      expect(stored.panel, 'custom');
      expect(stored.refHigh, 6.0);
    });

    test('a custom parameter joins the canonical ones in getParameters',
        () async {
      await db.insertCustomParameter(
        const Parameter(
          canonicalName: 'eosinophils_percent',
          displayName: 'Eosinophils %',
          defaultUnit: '%',
          panel: 'custom',
        ),
      );

      final all = await db.getParameters();
      expect(
        all,
        hasLength(ParameterDefinitions.canonicalParameters.length + 1),
      );
      expect(all.where((p) => p.isCustom), hasLength(1));
    });

    test('a custom parameter takes readings like any other', () async {
      final id = await db.insertCustomParameter(
        const Parameter(
          canonicalName: 'eosinophils_percent',
          displayName: 'Eosinophils %',
          defaultUnit: '%',
          panel: 'custom',
        ),
      );

      await insertReport(testDate: '2026-06-27', readings: [(id, 3.2)]);

      expect((await db.getLatestReading(id))!.value, 3.2);
    });
  });
}

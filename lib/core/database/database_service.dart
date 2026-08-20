import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../constants/parameter_definitions.dart';
import '../models/parameter.dart';
import '../models/reading.dart';
import '../models/report.dart';

/// Opens a database at [path]. Production supplies SQLCipher; tests substitute
/// an unencrypted in-memory database.
typedef DatabaseOpener = Future<Database> Function(
  String path, {
  required String password,
  required int version,
  required OnDatabaseCreateFn onCreate,
});

/// Singleton encrypted database service for MediScan.
///
/// Uses SQLCipher (via [sqflite_sqlcipher]) with a 256‑bit random key stored in
/// [FlutterSecureStorage]. The key is generated on first launch and is **not**
/// bound to biometric enrollment — on Android it uses
/// `encryptedSharedPreferences` so that a fingerprint change does not
/// invalidate the key.
///
/// All tables are created (and canonical parameters seeded) on first open.
///
/// The three things this class cannot do inside a unit test — resolve the
/// documents directory, read secure storage, and open a SQLCipher database —
/// are injectable via [DatabaseService.withOpener]. Everything else runs
/// identically under test.
class DatabaseService {
  DatabaseService._({
    Future<String> Function()? resolveDatabasePath,
    Future<String> Function()? resolveEncryptionKey,
    DatabaseOpener? opener,
  })  : _resolveDatabasePath = resolveDatabasePath ?? _documentsDirectoryPath,
        _resolveEncryptionKey = resolveEncryptionKey ?? _secureStorageKey,
        _open = opener ?? _openWithSqlCipher;

  static final DatabaseService instance = DatabaseService._();

  /// An isolated instance backed by [opener], for tests.
  ///
  /// Note what this does **not** cover: [opener] replaces the SQLCipher call
  /// entirely, so encryption itself is never exercised here. Tests using this
  /// factory verify schema, queries, and transactions — not that data at rest
  /// is encrypted. That requires a device.
  @visibleForTesting
  factory DatabaseService.withOpener(
    DatabaseOpener opener, {
    String path = ':memory:',
    String key = 'test-encryption-key',
  }) =>
      DatabaseService._(
        resolveDatabasePath: () async => path,
        resolveEncryptionKey: () async => key,
        opener: opener,
      );

  static const String _dbName = 'mediscan.db';
  static const String _keyStorageKey = 'mediscan_db_key';
  static const int _dbVersion = 1;

  final Future<String> Function() _resolveDatabasePath;
  final Future<String> Function() _resolveEncryptionKey;
  final DatabaseOpener _open;

  Database? _database;

  /// Returns the open database, initialising it if necessary.
  Future<Database> get database async {
    if (_database != null && _database!.isOpen) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  Future<Database> _initDatabase() async {
    final dbPath = await _resolveDatabasePath();
    final key = await _resolveEncryptionKey();

    return _open(
      dbPath,
      password: key,
      version: _dbVersion,
      onCreate: _onCreate,
    );
  }

  /// Production opener: SQLCipher, keyed by the secure-storage key.
  static Future<Database> _openWithSqlCipher(
    String path, {
    required String password,
    required int version,
    required OnDatabaseCreateFn onCreate,
  }) =>
      openDatabase(
        path,
        version: version,
        password: password,
        onCreate: onCreate,
      );

  /// Production path: `mediscan.db` in the app documents directory.
  static Future<String> _documentsDirectoryPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _dbName);
  }

  /// Retrieves the encryption key from secure storage, generating a new
  /// 256‑bit random key on first launch.
  static Future<String> _secureStorageKey() async {
    const storage = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );

    String? key = await storage.read(key: _keyStorageKey);
    if (key != null) return key;

    // Generate a 256‑bit (32‑byte) cryptographically strong random key.
    final random = Random.secure();
    final keyBytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      keyBytes[i] = random.nextInt(256);
    }
    key = base64Url.encode(keyBytes);

    await storage.write(key: _keyStorageKey, value: key);
    return key;
  }

  /// Creates all tables and seeds canonical parameters.
  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE parameters (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        canonical_name TEXT    NOT NULL UNIQUE,
        display_name   TEXT    NOT NULL,
        default_unit   TEXT    NOT NULL,
        ref_low        REAL,
        ref_high       REAL,
        ref_display    TEXT,
        panel          TEXT    NOT NULL,
        is_custom      INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE reports (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        scan_date TEXT    NOT NULL,
        test_date TEXT    NOT NULL,
        lab_name  TEXT,
        notes     TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE readings (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        report_id    INTEGER NOT NULL,
        parameter_id INTEGER NOT NULL,
        value        REAL    NOT NULL,
        unit         TEXT    NOT NULL,
        ref_low      REAL,
        ref_high     REAL,
        ref_display  TEXT,
        entry_type   TEXT    NOT NULL DEFAULT 'scan',
        created_at   TEXT    NOT NULL,
        FOREIGN KEY (report_id)    REFERENCES reports(id)    ON DELETE CASCADE,
        FOREIGN KEY (parameter_id) REFERENCES parameters(id) ON DELETE CASCADE
      )
    ''');

    // Seed canonical parameters.
    final batch = db.batch();
    for (final def in ParameterDefinitions.canonicalParameters) {
      batch.insert('parameters', {
        'canonical_name': def['canonicalName'] as String,
        'display_name': def['displayName'] as String,
        'default_unit': def['unit'] as String,
        'ref_low': def['refLow'] as double?,
        'ref_high': def['refHigh'] as double?,
        'ref_display': def['refDisplay'] as String?,
        'panel': def['panel'] as String,
        'is_custom': 0,
      });
    }
    await batch.commit(noResult: true);
  }

  // ---------------------------------------------------------------------------
  // Reports
  // ---------------------------------------------------------------------------

  /// Inserts a [report] and its associated [readings] in a single transaction.
  ///
  /// Each reading's `reportId` is set to the newly‑inserted report's `id`.
  /// Returns the inserted report's id.
  Future<int> insertReport(Report report, List<Reading> readings) async {
    final db = await database;
    late final int reportId;

    await db.transaction((txn) async {
      reportId = await txn.insert('reports', report.toMap());

      final batch = txn.batch();
      for (final reading in readings) {
        final map = reading.copyWith(reportId: reportId).toMap();
        // Remove any client‑side id so SQLite auto‑generates.
        map.remove('id');
        batch.insert('readings', map);
      }
      await batch.commit(noResult: true);
    });

    return reportId;
  }

  /// Returns all reports ordered by [testDate] descending (most recent first).
  Future<List<Report>> getReports() async {
    final db = await database;
    final rows = await db.query('reports', orderBy: 'test_date DESC');
    return rows.map(Report.fromMap).toList();
  }

  /// Returns a single report by its [id], or `null` if not found.
  Future<Report?> getReportById(int id) async {
    final db = await database;
    final rows = await db.query('reports', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Report.fromMap(rows.first);
  }

  /// Deletes a report and all its readings (cascading via foreign key).
  Future<void> deleteReport(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('readings', where: 'report_id = ?', whereArgs: [id]);
      await txn.delete('reports', where: 'id = ?', whereArgs: [id]);
    });
  }

  // ---------------------------------------------------------------------------
  // Readings
  // ---------------------------------------------------------------------------

  /// Returns all readings for the given [reportId].
  Future<List<Reading>> getReadingsForReport(int reportId) async {
    final db = await database;
    final rows = await db.query(
      'readings',
      where: 'report_id = ?',
      whereArgs: [reportId],
    );
    return rows.map(Reading.fromMap).toList();
  }

  /// Returns all readings for a given [parameterId], ordered by the parent
  /// report's [testDate] ascending — suitable for trend charts.
  Future<List<Reading>> getReadingsForParameter(int parameterId) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT r.*
      FROM readings r
      INNER JOIN reports rp ON rp.id = r.report_id
      WHERE r.parameter_id = ?
      ORDER BY rp.test_date ASC
      ''',
      [parameterId],
    );
    return rows.map(Reading.fromMap).toList();
  }

  /// Returns the most recent reading for the given [parameterId], determined
  /// by the parent report's maximum [testDate].
  Future<Reading?> getLatestReading(int parameterId) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT r.*
      FROM readings r
      INNER JOIN reports rp ON rp.id = r.report_id
      WHERE r.parameter_id = ?
      ORDER BY rp.test_date DESC
      LIMIT 1
      ''',
      [parameterId],
    );
    if (rows.isEmpty) return null;
    return Reading.fromMap(rows.first);
  }

  // ---------------------------------------------------------------------------
  // Parameters
  // ---------------------------------------------------------------------------

  /// Returns all parameters (canonical and custom).
  Future<List<Parameter>> getParameters() async {
    final db = await database;
    final rows = await db.query('parameters');
    return rows.map(Parameter.fromMap).toList();
  }

  /// Returns the parameter matching the given [canonicalName], or `null`.
  Future<Parameter?> getParameterByCanonicalName(String canonicalName) async {
    final db = await database;
    final rows = await db.query(
      'parameters',
      where: 'canonical_name = ?',
      whereArgs: [canonicalName],
    );
    if (rows.isEmpty) return null;
    return Parameter.fromMap(rows.first);
  }

  /// Inserts a user‑created custom parameter. Returns its new id.
  Future<int> insertCustomParameter(Parameter parameter) async {
    final db = await database;
    final map = parameter.copyWith(isCustom: true).toMap();
    map.remove('id');
    return db.insert('parameters', map);
  }

  // ---------------------------------------------------------------------------
  // Dashboard
  // ---------------------------------------------------------------------------

  /// Returns dashboard data: for each parameter that has at least one reading,
  /// returns the reading associated with the most recent [testDate].
  ///
  /// The result is a list of maps, each containing all reading columns plus
  /// `test_date`, `canonical_name`, `display_name`, `default_unit`, and
  /// `panel` from joined tables.
  Future<List<Map<String, dynamic>>> getDashboardData() async {
    final db = await database;
    return db.rawQuery('''
      SELECT r.*, rp.test_date, p.canonical_name, p.display_name,
             p.default_unit, p.panel
      FROM readings r
      INNER JOIN reports rp ON rp.id = r.report_id
      INNER JOIN parameters p ON p.id = r.parameter_id
      WHERE rp.test_date = (
        SELECT MAX(rp2.test_date)
        FROM readings r2
        INNER JOIN reports rp2 ON rp2.id = r2.report_id
        WHERE r2.parameter_id = r.parameter_id
      )
      ORDER BY p.panel, p.id
    ''');
  }

  // ---------------------------------------------------------------------------
  // Duplicate detection
  // ---------------------------------------------------------------------------

  /// Checks whether a report already exists for [testDate] whose readings
  /// share ≥ 50 % of the given [parameterIds].
  ///
  /// Returns the existing report if a duplicate is found, or `null` otherwise.
  Future<Report?> findDuplicateReport(
    String testDate,
    List<int> parameterIds,
  ) async {
    if (parameterIds.isEmpty) return null;

    final db = await database;

    // Find reports on the same test date.
    final reports = await db.query(
      'reports',
      where: 'test_date = ?',
      whereArgs: [testDate],
    );

    for (final row in reports) {
      final reportId = row['id'] as int;
      final existingReadings = await db.query(
        'readings',
        columns: ['parameter_id'],
        where: 'report_id = ?',
        whereArgs: [reportId],
      );

      final existingParamIds =
          existingReadings.map((r) => r['parameter_id'] as int).toSet();

      final overlap =
          parameterIds.where((id) => existingParamIds.contains(id)).length;

      // ≥ 50 % of the incoming parameter IDs overlap with existing report.
      if (overlap >= (parameterIds.length / 2).ceil()) {
        return Report.fromMap(row);
      }
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Closes the database connection. Call during app shutdown if needed.
  Future<void> close() async {
    final db = _database;
    if (db != null && db.isOpen) {
      await db.close();
      _database = null;
    }
  }
}

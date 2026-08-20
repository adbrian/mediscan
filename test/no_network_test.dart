import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Enforces the app's core invariant: **no health data leaves the device.**
///
/// Everything else in MediScan is a feature. This is the promise the product
/// is built on, the basis of the App Privacy and Data Safety declarations, and
/// the one property a user cannot verify for themselves. A failure here is a
/// release blocker, never a test to update.
///
/// There are three independent controls, in descending order of strength:
///
/// 1. **The Android release manifest declares no INTERNET permission.** The OS
///    refuses the syscall, so no code in the process can reach the network
///    whatever it was compiled from. This is the only control that holds
///    against a dependency we did not audit.
/// 2. **No direct dependency is an HTTP client, analytics, or crash reporter**,
///    and the direct dependency set is pinned so additions get reviewed.
/// 3. **No file under `lib/` imports a networking package or names a
///    networking type.** This governs code we actually wrote.
///
/// ## What these controls do not cover
///
/// `http` **is** in the dependency tree, pulled in transitively by three
/// direct dependencies that cannot be dropped:
///
/// * `syncfusion_flutter_pdf` — PDF text-layer extraction
/// * `image_picker` (via `image_picker_platform_interface`)
/// * `file_picker` (via `file_selector_platform_interface`)
///
/// So "no HTTP client in the binary" is not achievable and is not what is
/// claimed. What is claimed is that no MediScan code calls one, and that on
/// Android release builds the platform would refuse the call anyway. iOS has
/// no equivalent permission gate, so control 1 is Android-only there — which
/// is precisely why controls 2 and 3 are not redundant.
///
/// Residual risk worth verifying on a device: a PDF referencing a remote font
/// or image could in principle prompt Syncfusion to fetch it. On Android
/// release the manifest blocks that. On iOS it would not be blocked, so
/// confirm behaviour with a PDF containing a remote resource before shipping.
void main() {
  /// Package names that exist to move bytes off the device.
  const networkPackages = <String>{
    'http',
    'dio',
    'chopper',
    'retrofit',
    'grpc',
    'graphql',
    'graphql_flutter',
    'web_socket_channel',
    'socket_io_client',
    'googleapis',
    'gsheets',
    'supabase',
    'supabase_flutter',
    'aws_client',
    'universal_html',
  };

  /// Packages that report usage or crashes to a third party.
  const telemetryPackages = <String>{
    'firebase_core',
    'firebase_analytics',
    'firebase_crashlytics',
    'firebase_performance',
    'sentry',
    'sentry_flutter',
    'posthog_flutter',
    'amplitude_flutter',
    'mixpanel_flutter',
    'segment_analytics',
    'appsflyer_sdk',
    'facebook_app_events',
    'datadog_flutter_plugin',
    'bugsnag_flutter',
    'catcher',
  };

  /// The reviewed direct dependency set. Pinned deliberately: adding a package
  /// is the moment to check whether it can reach the network, and this test
  /// makes that moment impossible to skip.
  const reviewedDependencies = <String>{
    // Flutter SDK
    'flutter',
    'flutter_test',
    'flutter_lints',
    // Test-only. Audited 2026-08-21: pulls in sqlite3, ffi, synchronized and
    // meta, and adds no new transitive HTTP source. Dev-only, so it is not in
    // the shipped binary at all.
    'sqflite_common_ffi',
    // Capture and extraction — all on-device
    'google_mlkit_text_recognition',
    'pdfx',
    'syncfusion_flutter_pdf',
    'image_picker',
    'file_picker',
    // Storage and secrets
    'sqflite_sqlcipher',
    'flutter_secure_storage',
    'path_provider',
    'path',
    // UI and utility
    'fl_chart',
    'provider',
    'intl',
    'string_similarity',
    'local_auth',
  };

  String readOrFail(String relativePath) {
    final file = File(relativePath);
    if (!file.existsSync()) {
      fail(
        'Could not read $relativePath from ${Directory.current.path}. '
        'This test expects to run with the package root as the working '
        'directory, which is what `flutter test` does.',
      );
    }
    return file.readAsStringSync();
  }

  /// Removes comments so a doc comment mentioning a banned name does not read
  /// as usage. Imperfect for `//` inside string literals; the codebase has
  /// none, and import scanning below does not rely on this.
  String stripComments(String source) => source
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i == -1 ? l : l.substring(0, i);
      })
      .join('\n');

  /// Package names declared under `dependencies:` / `dev_dependencies:`.
  Set<String> declaredDependencies(String pubspec) {
    final names = <String>{};
    var section = '';
    for (final line in pubspec.split('\n')) {
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
      if (!line.startsWith(' ')) {
        section = line.split(':').first.trim();
        continue;
      }
      if (section != 'dependencies' && section != 'dev_dependencies') continue;
      // Package entries sit at exactly two spaces; their keys (sdk:, version:)
      // are indented further.
      final match = RegExp(r'^  ([a-z0-9_]+):').firstMatch(line);
      if (match != null) names.add(match.group(1)!);
    }
    return names;
  }

  List<File> dartFilesUnderLib() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  group('control 1: Android release manifest', () {
    test('declares no INTERNET permission', () {
      final manifest = readOrFail('android/app/src/main/AndroidManifest.xml');
      expect(
        manifest.contains('android.permission.INTERNET'),
        isFalse,
        reason: 'Adding INTERNET to the release manifest removes the only '
            'control that holds against an unaudited dependency. If a feature '
            'appears to need it, that feature is out of scope for V1.',
      );
    });

    test('declares only the permissions the app actually needs', () {
      final manifest = readOrFail('android/app/src/main/AndroidManifest.xml');
      final declared = RegExp(r'android:name="android\.permission\.(\w+)"')
          .allMatches(manifest)
          .map((m) => m.group(1)!)
          .toSet();

      expect(
        declared,
        equals({'CAMERA', 'USE_BIOMETRIC', 'USE_FINGERPRINT'}),
        reason: 'A new permission needs a privacy review before it ships.',
      );
    });

    test('debug and profile manifests may keep INTERNET for tooling', () {
      // Flutter's debug and profile manifests add INTERNET so hot reload and
      // the observatory work. Those variants never ship. Asserted so the
      // difference is understood as intentional rather than found later and
      // mistaken for a leak.
      for (final variant in ['debug', 'profile']) {
        final path = 'android/app/src/$variant/AndroidManifest.xml';
        if (!File(path).existsSync()) continue;
        expect(
          readOrFail(path).contains('android.permission.INTERNET'),
          isTrue,
          reason: '$variant is expected to carry INTERNET for dev tooling',
        );
      }
    });
  });

  group('control 2: direct dependencies', () {
    test('declares no HTTP client', () {
      final declared = declaredDependencies(readOrFail('pubspec.yaml'));
      final offenders = declared.intersection(networkPackages);
      expect(
        offenders,
        isEmpty,
        reason: 'These packages exist to make network calls: $offenders',
      );
    });

    test('declares no analytics or crash-reporting SDK', () {
      final declared = declaredDependencies(readOrFail('pubspec.yaml'));
      final offenders = declared.intersection(telemetryPackages);
      expect(
        offenders,
        isEmpty,
        reason: 'V1 ships no telemetry of any kind. Found: $offenders',
      );
    });

    test('the direct dependency set matches the reviewed list', () {
      final declared = declaredDependencies(readOrFail('pubspec.yaml'));

      expect(
        declared,
        equals(reviewedDependencies),
        reason: 'A dependency was added or removed. Before updating this list, '
            'run `flutter pub deps --style=compact` and confirm what the new '
            'package pulls in — a transitive HTTP client is invisible in '
            'pubspec.yaml. If it needs network access to function, it does not '
            'belong in this app.',
      );
    });
  });

  group('control 3: lib/ source', () {
    const bannedImports = <String>[
      'package:http/',
      'package:dio/',
      'package:chopper/',
      'package:grpc/',
      'package:graphql',
      'package:web_socket_channel/',
      'package:socket_io_client/',
      'package:googleapis',
      'package:supabase',
      'package:firebase',
      'package:sentry',
      'dart:html',
      'package:web/',
    ];

    test('no file imports a networking package', () {
      final offenders = <String>[];

      for (final file in dartFilesUnderLib()) {
        for (final line in file.readAsStringSync().split('\n')) {
          final trimmed = line.trimLeft();
          if (!trimmed.startsWith('import ') && !trimmed.startsWith('export ')) {
            continue;
          }
          for (final banned in bannedImports) {
            if (trimmed.contains(banned)) {
              offenders.add('${file.path}: $trimmed');
            }
          }
        }
      }

      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('no file names a networking type', () {
      // dart:io itself is legitimate — OcrService needs Platform, and
      // PdfImportService reads the user's chosen file. What must not appear is
      // the part of dart:io that opens a connection.
      final banned = <RegExp>[
        RegExp(r'\bHttpClient\b'),
        RegExp(r'\bHttpServer\b'),
        RegExp(r'\bWebSocket\b'),
        RegExp(r'\bRawSocket\b'),
        RegExp(r'\bSecureSocket\b'),
        RegExp(r'\bServerSocket\b'),
        RegExp(r'\bInternetAddress\b'),
        RegExp(r'\bSocket\s*\.\s*connect\b'),
      ];

      final offenders = <String>[];
      for (final file in dartFilesUnderLib()) {
        final source = stripComments(file.readAsStringSync());
        for (final pattern in banned) {
          if (pattern.hasMatch(source)) {
            offenders.add('${file.path}: ${pattern.pattern}');
          }
        }
      }

      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('the scan actually covers the source tree', () {
      // A scan that silently matches nothing passes forever. Anchor it.
      final files = dartFilesUnderLib();
      expect(files.length, greaterThanOrEqualTo(10));
      expect(
        files.map((f) => f.path),
        contains('lib/modules/ocr/ocr_service.dart'),
      );
    });

    test('the banned-type scan detects a violation when one exists', () {
      // Proves the matcher works rather than trusting an empty result.
      const sample = '''
        import 'dart:io';
        void send() { final c = HttpClient(); }
      ''';
      expect(RegExp(r'\bHttpClient\b').hasMatch(stripComments(sample)), isTrue);

      // And that a doc comment mentioning it does not count as usage.
      const mention = '/// Never use HttpClient here.\nvoid noop() {}';
      expect(RegExp(r'\bHttpClient\b').hasMatch(stripComments(mention)), isFalse);
    });
  });
}

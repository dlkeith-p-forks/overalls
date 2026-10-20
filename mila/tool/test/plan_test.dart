import 'package:hegel/hegel.dart' hide Mode;
import 'package:mila_build/mila_build.dart';
import 'package:test/test.dart';

const String _version = '0.1.0+7';

const BuildInputs _signed = BuildInputs(
  appleTeam: 'ABCDE12345',
  appleIdentity: 'Developer ID Application: Overalls (ABCDE12345)',
  appleProfileRunner: 'Mila Developer ID',
  appleProfileNotificationService: 'Mila Notifications Developer ID',
  notaryProfile: 'mila-notary',
  iosExportOptions: '/secure/ExportOptions.plist',
  androidUpload: {
    'storeFile': '/secure/upload.jks',
    'storePassword': 'store-secret',
    'keyAlias': 'upload',
    'keyPassword': 'key-secret',
  },
  windowsPublisher: 'CN=Overalls, O=Overalls, C=AU',
  windowsCertificateSha1: '0123456789abcdef0123456789abcdef01234567',
);

Host _hostFor(Platform platform) => switch (platform) {
  Platform.ios || Platform.macos => Host.macos,
  Platform.windows => Host.windows,
  Platform.linux || Platform.android => Host.linux,
};

Planned _planned(Platform platform, Mode mode, BuildInputs inputs) {
  final result = plan(platform, mode, host: _hostFor(platform), inputs: inputs, version: _version);
  if (result is! Planned) fail('expected a plan, got ${(result as Refused).reason}');
  return result;
}

Iterable<String> _arguments(Planned planned) =>
    planned.steps.whereType<Run>().expand((r) => [...r.arguments, ...r.environment.values]);

void main() {
  group('dev targets', () {
    test('an unsigned macOS dev build keeps software keys and no push', () {
      final planned = _planned(Platform.macos, Mode.dev, const BuildInputs());
      final build = planned.steps.whereType<Run>().first;
      expect(build.arguments, containsAll(['--debug', '--dart-define=MILA_SOFTWARE_KEYS=true']));
      expect(build.environment, {'FLUTTER_XCODE_MILA_SIGNING': 'unsigned'});
      expect(build.remove, containsAll(['SDKROOT', 'CC', 'LD']));
      expect(build.appleToolchain, isTrue);
    });

    test('a team-signed macOS dev build uses the Secure Enclave and the APNs sandbox', () {
      final planned = _planned(Platform.macos, Mode.dev, const BuildInputs(appleTeam: 'T1'));
      final build = planned.steps.whereType<Run>().first;
      expect(build.arguments, isNot(contains('--dart-define=MILA_SOFTWARE_KEYS=true')));
      expect(build.environment['FLUTTER_XCODE_MILA_SIGNING'], 'development');
      expect(build.environment['FLUTTER_XCODE_DEVELOPMENT_TEAM'], 'T1');
    });

    test('demo is allowed in dev and selects the demo flavour', () {
      final linux = _planned(Platform.linux, Mode.dev, const BuildInputs(demo: true));
      expect(_arguments(linux), contains('.#tool-mila-demo'));
      final macos = _planned(Platform.macos, Mode.dev, const BuildInputs(demo: true));
      expect(_arguments(macos), contains('--dart-define=MILA_DEMO=true'));
    });

    test('an iOS dev build without a team targets the simulator', () {
      final planned = _planned(Platform.ios, Mode.dev, const BuildInputs());
      expect(_arguments(planned), containsAll(['--simulator', '--debug']));
    });

    test('a Windows dev build stages an unsigned layout with a development publisher', () {
      final planned = _planned(Platform.windows, Mode.dev, const BuildInputs());
      final manifest = planned.steps.whereType<WriteManifest>().single;
      expect(manifest.publisher, 'CN=Mila Development');
      expect(manifest.version, '0.1.0.0');
      expect(
        planned.steps.whereType<Run>().map((r) => r.executable),
        isNot(contains('signtool.exe')),
      );
      expect(planned.notes.single, contains('Add-AppxPackage -Register'));
    });
  });

  group('release targets', () {
    test('every release target signs and then verifies', () {
      final verifiers = {
        Platform.android: 'jarsigner',
        Platform.macos: 'spctl',
        Platform.windows: 'signtool.exe',
      };
      for (final MapEntry(key: platform, value: verifier) in verifiers.entries) {
        final runs = _planned(platform, Mode.release, _signed).steps.whereType<Run>();
        expect(runs.map((r) => r.executable), contains(verifier), reason: platform.name);
      }
      final windows = _planned(
        Platform.windows,
        Mode.release,
        _signed,
      ).steps.whereType<Run>().map((r) => r.arguments.first).toList();
      expect(windows.indexOf('sign'), lessThan(windows.indexOf('verify')));
    });

    test('macOS release is Developer ID signed, notarized, stapled and assessed', () {
      final runs = _planned(Platform.macos, Mode.release, _signed).steps.whereType<Run>().toList();
      final build = runs.first;
      expect(build.arguments, contains('--release'));
      expect(build.environment['FLUTTER_XCODE_MILA_SIGNING'], 'release');
      expect(build.environment['FLUTTER_XCODE_CODE_SIGN_IDENTITY'], _signed.appleIdentity);
      final order = runs.map(
        (r) => r.arguments.isEmpty ? r.executable : '${r.executable} ${r.arguments.first}',
      );
      expect(
        order.toList(),
        containsAllInOrder([
          'flutter build',
          'codesign --verify',
          'hdiutil create',
          'codesign --sign',
          'xcrun notarytool',
          'xcrun stapler',
          'spctl --assess',
        ]),
      );
    });

    test('a missing signing input is refused, never replaced', () {
      for (final platform in [Platform.android, Platform.ios, Platform.macos, Platform.windows]) {
        final result = plan(
          platform,
          Mode.release,
          host: _hostFor(platform),
          inputs: const BuildInputs(),
          version: _version,
        );
        expect(result, isA<Refused>(), reason: platform.name);
      }
    });

    test('Android upload passwords reach Gradle only through redacted environment', () {
      final run = _planned(Platform.android, Mode.release, _signed).steps.whereType<Run>().first;
      expect(run.arguments.join(' '), isNot(contains('secret')));
      expect(run.environment['ORG_GRADLE_PROJECT_mila.upload.storePassword'], 'store-secret');
      expect(run.describe(), isNot(contains('secret')));
    });
  });

  test('builds for another host are refused', () {
    expect(
      plan(
        Platform.macos,
        Mode.dev,
        host: Host.linux,
        inputs: const BuildInputs(),
        version: _version,
      ),
      isA<Refused>(),
    );
    expect(
      plan(
        Platform.windows,
        Mode.dev,
        host: Host.macos,
        inputs: const BuildInputs(),
        version: _version,
      ),
      isA<Refused>(),
    );
  });

  test('inputs are read from MILA_ variables, empty values unset', () {
    final inputs = BuildInputs.fromEnvironment({
      'MILA_APPLE_TEAM': 'T1',
      'MILA_NOTARY_PROFILE': '',
      'MILA_ANDROID_UPLOAD_STORE_FILE': 'a.jks',
      'MILA_ANDROID_UPLOAD_STORE_PASSWORD': 'p',
      'MILA_ANDROID_UPLOAD_KEY_ALIAS': 'k',
      'MILA_FCM_PROJECT_ID': 'mila-push',
    }, demo: false);
    expect(inputs.appleTeam, 'T1');
    expect(inputs.notaryProfile, isNull);
    expect(inputs.androidUpload, isNull, reason: 'one of four upload fields is missing');
    expect(inputs.fcm, {'projectId': 'mila-push'});
  });

  // Checks mila-build-release-contract in lib/src/plan.dart
  property('release plans never enable demo or software keys and keep secrets out of arguments', (
    tc,
  ) {
    final platform = tc.draw(sampledFrom(Platform.values), name: 'platform');
    final host = tc.draw(sampledFrom(Host.values), name: 'host');
    final demo = tc.draw(booleans(), name: 'demo');
    final team = tc.draw(booleans(), name: 'team');
    final inputs = BuildInputs(
      demo: demo,
      appleTeam: team ? _signed.appleTeam : null,
      appleIdentity: _signed.appleIdentity,
      appleProfileRunner: _signed.appleProfileRunner,
      appleProfileNotificationService: _signed.appleProfileNotificationService,
      notaryProfile: _signed.notaryProfile,
      iosExportOptions: _signed.iosExportOptions,
      androidUpload: _signed.androidUpload,
      windowsPublisher: _signed.windowsPublisher,
      windowsCertificateSha1: _signed.windowsCertificateSha1,
    );
    final result = plan(platform, Mode.release, host: host, inputs: inputs, version: _version);
    if (demo) {
      expect(result, isA<Refused>());
      return;
    }
    if (result is! Planned) return;
    final runs = result.steps.whereType<Run>().toList();
    final arguments = runs.expand((r) => r.arguments).toList();
    expect(arguments, isNot(contains('--debug')));
    expect(
      arguments.where((a) => a.contains('MILA_DEMO') || a.contains('MILA_SOFTWARE_KEYS')),
      isEmpty,
    );
    expect(arguments.join(' '), isNot(contains('secret')));
    for (final run in runs) {
      expect(run.describe(), isNot(contains('secret')));
      expect(run.environment['FLUTTER_XCODE_MILA_SIGNING'], anyOf(isNull, 'release'));
    }
  });
}

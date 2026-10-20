// What each Mila build target does, as data (ADR-0235). `plan` is pure: it
// turns a platform, a mode, the host and the signing inputs into the exact
// steps to run, or a refusal naming what is missing. `execute.dart` runs the
// steps; nothing here touches the file system or the environment.

/// The platforms Mila builds for.
enum Platform {
  linux,
  android,
  ios,
  macos,
  windows;

  static Platform? parse(String value) => values.where((p) => p.name == value).firstOrNull;
}

/// `dev`: debug mode, development push, unsigned or development-signed,
/// demo permitted. `release`: release mode, production push, signed and
/// verified, demo refused.
enum Mode {
  dev,
  release;

  static Mode? parse(String value) => values.where((m) => m.name == value).firstOrNull;
}

/// The OS the build runs on.
enum Host { linux, macos, windows }

/// The pinned Flutter (ADR-0227); builds outside Nix refuse any other.
const String pinnedFlutter = '3.47.0';

/// Toolchain variables devenv exports on macOS that break Xcode builds: they
/// point at Nix's SDK and compilers instead of Xcode's.
const List<String> nixToolchainVariables = [
  'SDKROOT',
  'CC',
  'CXX',
  'LD',
  'AR',
  'NM',
  'RANLIB',
  'STRIP',
  'MACOSX_DEPLOYMENT_TARGET',
  'NIX_CFLAGS_COMPILE',
  'NIX_LDFLAGS',
  'NIX_CC',
  'NIX_BINTOOLS',
];

/// Signing inputs and options, read from `MILA_*` environment variables by
/// [BuildInputs.fromEnvironment]. Secrets are only ever passed to steps
/// through their environment, never their arguments.
final class BuildInputs {
  const BuildInputs({
    this.demo = false,
    this.appleTeam,
    this.appleIdentity,
    this.appleProfileRunner,
    this.appleProfileNotificationService,
    this.notaryProfile,
    this.iosExportOptions,
    this.androidUpload,
    this.fcm = const {},
    this.windowsPublisher,
    this.windowsCertificateSha1,
    this.windowsTimestampUrl = 'http://timestamp.digicert.com',
  });

  /// `--demo`: the in-memory deployment (dev only).
  final bool demo;

  /// The Apple Developer team ID; without it Apple dev builds are unsigned.
  final String? appleTeam;

  /// The macOS release signing identity, e.g. `Developer ID Application: … (TEAM)`.
  final String? appleIdentity;

  /// macOS release provisioning profile names for the app and its extension.
  final String? appleProfileRunner;
  final String? appleProfileNotificationService;

  /// A `notarytool store-credentials` keychain profile name.
  final String? notaryProfile;

  /// An `ExportOptions.plist` for `flutter build ipa`.
  final String? iosExportOptions;

  /// The Play upload key: `storeFile`, `storePassword`, `keyAlias`, `keyPassword`.
  final Map<String, String>? androidUpload;

  /// FCM configuration Gradle properties (`mila.fcm.*`), possibly empty.
  final Map<String, String> fcm;

  /// The MSIX publisher; MUST equal the signing certificate's subject.
  final String? windowsPublisher;

  /// The SHA-1 thumbprint of the code-signing certificate in the user store.
  final String? windowsCertificateSha1;
  final String windowsTimestampUrl;

  static const List<String> androidUploadFields = [
    'storeFile',
    'storePassword',
    'keyAlias',
    'keyPassword',
  ];

  static const Map<String, String> _fcmVariables = {
    'MILA_FCM_PROJECT_ID': 'projectId',
    'MILA_FCM_APPLICATION_ID': 'applicationId',
    'MILA_FCM_API_KEY': 'apiKey',
    'MILA_FCM_SENDER_ID': 'senderId',
  };

  /// Reads the inputs from `MILA_*` variables; empty values count as unset.
  factory BuildInputs.fromEnvironment(Map<String, String> env, {required bool demo}) {
    String? read(String name) {
      final value = env[name];
      return value == null || value.isEmpty ? null : value;
    }

    final upload = {
      for (final field in androidUploadFields) field: read('MILA_ANDROID_UPLOAD_${_snake(field)}'),
    };
    return BuildInputs(
      demo: demo,
      appleTeam: read('MILA_APPLE_TEAM'),
      appleIdentity: read('MILA_APPLE_IDENTITY'),
      appleProfileRunner: read('MILA_APPLE_PROFILE_RUNNER'),
      appleProfileNotificationService: read('MILA_APPLE_PROFILE_NOTIFICATION_SERVICE'),
      notaryProfile: read('MILA_NOTARY_PROFILE'),
      iosExportOptions: read('MILA_IOS_EXPORT_OPTIONS'),
      androidUpload: upload.values.every((v) => v != null)
          ? {for (final e in upload.entries) e.key: e.value!}
          : null,
      fcm: {for (final e in _fcmVariables.entries) e.value: ?read(e.key)},
      windowsPublisher: read('MILA_WINDOWS_PUBLISHER'),
      windowsCertificateSha1: read('MILA_WINDOWS_CERT_SHA1'),
      windowsTimestampUrl: read('MILA_WINDOWS_TIMESTAMP_URL') ?? 'http://timestamp.digicert.com',
    );
  }

  static String _snake(String field) =>
      field.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]}').toUpperCase();
}

/// One thing a build does.
sealed class Step {
  const Step();

  /// What the step does, without any secret.
  String describe();
}

/// Runs a program. [environment] is added to the step's environment and
/// [remove] taken out of it; [secrets] names the [environment] keys whose
/// values are never shown.
final class Run extends Step {
  const Run(
    this.executable,
    this.arguments, {
    required this.directory,
    this.environment = const {},
    this.remove = const [],
    this.secrets = const {},
    this.appleToolchain = false,
  });

  final String executable;
  final List<String> arguments;

  /// Relative to the repository root.
  final String directory;
  final Map<String, String> environment;
  final List<String> remove;
  final Set<String> secrets;

  /// Use Xcode's toolchain: put `/usr/bin` (xcrun) and a GNU rsync ahead of
  /// devenv's tools. macOS's openrsync ignores the `--chmod` Flutter passes
  /// when copying its framework, so a Nix-store framework stays read-only.
  final bool appleToolchain;

  @override
  String describe() {
    final shown = [
      for (final e in environment.entries)
        '${e.key}=${secrets.contains(e.key) ? '<redacted>' : e.value}',
    ];
    return [...shown, executable, ...arguments].join(' ');
  }
}

/// Copies a directory tree, replacing [to].
final class CopyTree extends Step {
  const CopyTree(this.from, this.to);
  final String from;
  final String to;

  @override
  String describe() => 'copy $from -> $to';
}

/// Writes the MSIX manifest from its template.
final class WriteManifest extends Step {
  const WriteManifest({
    required this.template,
    required this.to,
    required this.publisher,
    required this.version,
  });
  final String template;
  final String to;
  final String publisher;

  /// The four-part MSIX version.
  final String version;

  @override
  String describe() => 'manifest $template -> $to ($publisher, $version)';
}

/// Records SHA-256 checksums of [files] in `SHA256SUMS` beside them.
final class Checksums extends Step {
  const Checksums(this.directory, this.files);
  final String directory;
  final List<String> files;

  @override
  String describe() => 'sha256 $directory/{${files.join(',')}}';
}

/// The outcome of planning.
sealed class Plan {
  const Plan();
}

final class Planned extends Plan {
  const Planned(this.steps, {required this.artifacts, this.notes = const []});
  final List<Step> steps;

  /// What the build leaves behind, relative to the repository root.
  final List<String> artifacts;

  /// Instructions for the person running the build (e.g. how to install).
  final List<String> notes;
}

final class Refused extends Plan {
  const Refused(this.reason);
  final String reason;
}

/// The Mila app directory, relative to the repository root.
const String appDirectory = 'mila/app';

/// Where `mila-build` puts its outputs, relative to the repository root.
String outputDirectory(Platform platform, Mode mode) => 'mila/build/${platform.name}-${mode.name}';

// @cc [owner:ghuntley,label:security;build] mila-build-release-contract
// A release plan MUST NOT enable the demo deployment or software keys, MUST
// build in release mode with production push, MUST sign and then verify the
// signature, and MUST refuse rather than fall back when a signing input is
// missing. Secrets MUST reach steps only through redacted environment
// variables, never arguments.
/// The steps for [platform] in [mode] on [host] with [inputs], given the
/// app's [version] (`pubspec.yaml`, e.g. `0.1.0+1`).
Plan plan(
  Platform platform,
  Mode mode, {
  required Host host,
  required BuildInputs inputs,
  required String version,
}) {
  if (inputs.demo && mode == Mode.release) {
    return const Refused('--demo is for dev builds only');
  }
  final release = mode == Mode.release;
  final out = outputDirectory(platform, mode);
  final flutterMode = release ? '--release' : '--debug';
  final demo = [if (inputs.demo) '--dart-define=MILA_DEMO=true'];

  switch (platform) {
    case Platform.linux:
      final attribute = release
          ? 'tool-mila-linux-release'
          : inputs.demo
          ? 'tool-mila-demo'
          : 'tool-mila-linux-dev';
      return Planned(
        [
          Run('nix', ['build', '.#$attribute', '--out-link', out], directory: '.'),
        ],
        artifacts: [out],
      );

    case Platform.android:
      if (!release) {
        if (inputs.demo) return const Refused('the Android dev APK has no demo flavour');
        return Planned(
          [
            Run('nix', ['build', '.#tool-mila-android', '--out-link', out], directory: '.'),
          ],
          artifacts: [out],
          notes: const ['debug-key signed and without FCM configuration'],
        );
      }
      final upload = inputs.androidUpload;
      if (upload == null) {
        return const Refused(
          'android release needs MILA_ANDROID_UPLOAD_STORE_FILE, _STORE_PASSWORD, '
          '_KEY_ALIAS and _KEY_PASSWORD',
        );
      }
      final gradle = {
        for (final e in upload.entries) 'ORG_GRADLE_PROJECT_mila.upload.${e.key}': e.value,
        for (final e in inputs.fcm.entries) 'ORG_GRADLE_PROJECT_mila.fcm.${e.key}': e.value,
      };
      const bundle = '$appDirectory/build/app/outputs/bundle/release/app-release.aab';
      return Planned(
        [
          Run(
            'flutter',
            ['build', 'appbundle', '--release'],
            directory: appDirectory,
            environment: gradle,
            secrets: {
              'ORG_GRADLE_PROJECT_mila.upload.storePassword',
              'ORG_GRADLE_PROJECT_mila.upload.keyPassword',
            },
          ),
          Run('jarsigner', ['-verify', '-strict', bundle], directory: '.'),
          CopyTree('$appDirectory/build/app/outputs/bundle/release', out),
          Checksums(out, const ['app-release.aab']),
        ],
        artifacts: ['$out/app-release.aab'],
      );

    case Platform.ios:
      if (host != Host.macos) return const Refused('iOS builds need a Mac with Xcode');
      final team = inputs.appleTeam;
      if (!release) {
        return Planned(
          [
            if (team == null)
              _apple(['build', 'ios', '--simulator', '--debug', ...demo])
            else
              _apple(
                ['build', 'ios', '--debug', ...demo],
                settings: {'DEVELOPMENT_TEAM': team, 'CODE_SIGN_STYLE': 'Automatic'},
              ),
          ],
          artifacts: [
            team == null
                ? '$appDirectory/build/ios/iphonesimulator/Runner.app'
                : '$appDirectory/build/ios/iphoneos/Runner.app',
          ],
          notes: [if (team == null) 'simulator build: set MILA_APPLE_TEAM for a device build'],
        );
      }
      final options = inputs.iosExportOptions;
      if (team == null || options == null) {
        return const Refused('ios release needs MILA_APPLE_TEAM and MILA_IOS_EXPORT_OPTIONS');
      }
      return Planned(
        [
          _apple(
            ['build', 'ipa', '--release', '--export-options-plist=$options'],
            settings: {'DEVELOPMENT_TEAM': team},
          ),
          CopyTree('$appDirectory/build/ios/ipa', out),
        ],
        artifacts: [out],
      );

    case Platform.macos:
      if (host != Host.macos) return const Refused('macOS builds need a Mac with Xcode');
      final team = inputs.appleTeam;
      const debugApp = '$appDirectory/build/macos/Build/Products/Debug/mila.app';
      const releaseApp = '$appDirectory/build/macos/Build/Products/Release/mila.app';
      if (!release) {
        if (team == null) {
          return Planned(
            [
              _apple(
                ['build', 'macos', '--debug', '--dart-define=MILA_SOFTWARE_KEYS=true', ...demo],
                settings: {'MILA_SIGNING': 'unsigned'},
              ),
              _verifyApp(debugApp),
            ],
            artifacts: const [debugApp],
            notes: const [
              'unsigned: owner-only software keys and no push; set MILA_APPLE_TEAM for '
                  'Secure Enclave keys and the APNs sandbox',
            ],
          );
        }
        return Planned(
          [
            _apple(
              ['build', 'macos', '--debug', ...demo],
              settings: {
                'MILA_SIGNING': 'development',
                'DEVELOPMENT_TEAM': team,
                'CODE_SIGN_STYLE': 'Automatic',
                'CODE_SIGN_IDENTITY': 'Apple Development',
              },
            ),
            _verifyApp(debugApp),
          ],
          artifacts: const [debugApp],
        );
      }
      final identity = inputs.appleIdentity;
      final runnerProfile = inputs.appleProfileRunner;
      final extensionProfile = inputs.appleProfileNotificationService;
      final notary = inputs.notaryProfile;
      if (team == null ||
          identity == null ||
          runnerProfile == null ||
          extensionProfile == null ||
          notary == null) {
        return const Refused(
          'macos release needs MILA_APPLE_TEAM, MILA_APPLE_IDENTITY, MILA_APPLE_PROFILE_RUNNER, '
          'MILA_APPLE_PROFILE_NOTIFICATION_SERVICE and MILA_NOTARY_PROFILE',
        );
      }
      final dmgName = 'Mila-${_marketing(version)}.dmg';
      final dmg = '$out/$dmgName';
      return Planned(
        [
          _apple(
            ['build', 'macos', '--release'],
            settings: {
              'MILA_SIGNING': 'release',
              'DEVELOPMENT_TEAM': team,
              'CODE_SIGN_STYLE': 'Manual',
              'CODE_SIGN_IDENTITY': identity,
              'MILA_PROFILE_RUNNER': runnerProfile,
              'MILA_PROFILE_NOTIFICATION_SERVICE': extensionProfile,
              'OTHER_CODE_SIGN_FLAGS': '--timestamp',
            },
          ),
          _verifyApp(releaseApp),
          Run('mkdir', ['-p', out], directory: '.'),
          Run('hdiutil', [
            'create',
            '-volname',
            'Mila',
            '-srcfolder',
            releaseApp,
            '-ov',
            '-format',
            'UDZO',
            dmg,
          ], directory: '.'),
          Run('codesign', ['--sign', identity, '--timestamp', dmg], directory: '.'),
          Run(
            'xcrun',
            ['notarytool', 'submit', dmg, '--keychain-profile', notary, '--wait'],
            directory: '.',
            appleToolchain: true,
          ),
          Run('xcrun', ['stapler', 'staple', dmg], directory: '.', appleToolchain: true),
          Run('spctl', [
            '--assess',
            '--type',
            'open',
            '--context',
            'context:primary-signature',
            '-vv',
            dmg,
          ], directory: '.'),
          Checksums(out, [dmgName]),
        ],
        artifacts: [dmg],
      );

    case Platform.windows:
      if (host != Host.windows) return const Refused('Windows builds need Windows');
      final publisher = release ? inputs.windowsPublisher : 'CN=Mila Development';
      final thumbprint = inputs.windowsCertificateSha1;
      if (release && (publisher == null || thumbprint == null)) {
        return const Refused(
          'windows release needs MILA_WINDOWS_PUBLISHER and MILA_WINDOWS_CERT_SHA1',
        );
      }
      final configuration = release ? 'Release' : 'Debug';
      final layout = '$out/layout';
      final msixName = 'Mila-${_marketing(version)}.msix';
      final msix = '$out/$msixName';
      final stage = <Step>[
        Run('flutter', ['build', 'windows', flutterMode, ...demo], directory: appDirectory),
        CopyTree('$appDirectory/build/windows/x64/runner/$configuration', layout),
        CopyTree('$appDirectory/windows/msix/Assets', '$layout/Assets'),
        WriteManifest(
          template: '$appDirectory/windows/msix/AppxManifest.xml.in',
          to: '$layout/AppxManifest.xml',
          publisher: publisher!,
          version: _msixVersion(version),
        ),
      ];
      if (!release) {
        return Planned(
          stage,
          artifacts: [layout],
          notes: [
            'unsigned dev layout: register it with '
                r'`Add-AppxPackage -Register .\'
                '${layout.replaceAll('/', r'\')}\\AppxManifest.xml` (Developer Mode), which '
                'gives Mila the package identity WNS needs',
          ],
        );
      }
      return Planned(
        [
          ...stage,
          Run('makeappx.exe', ['pack', '/o', '/d', layout, '/p', msix], directory: '.'),
          Run('signtool.exe', [
            'sign',
            '/fd',
            'SHA256',
            '/sha1',
            thumbprint!,
            '/tr',
            inputs.windowsTimestampUrl,
            '/td',
            'SHA256',
            msix,
          ], directory: '.'),
          Run('signtool.exe', ['verify', '/pa', '/v', msix], directory: '.'),
          Checksums(out, [msixName]),
        ],
        artifacts: [msix],
      );
  }
}

/// A Flutter build for an Apple platform, with Xcode's toolchain and
/// [settings] passed to every Xcode target as `FLUTTER_XCODE_` variables.
Run _apple(List<String> arguments, {Map<String, String> settings = const {}}) => Run(
  'flutter',
  arguments,
  directory: appDirectory,
  environment: {for (final e in settings.entries) 'FLUTTER_XCODE_${e.key}': e.value},
  remove: nixToolchainVariables,
  appleToolchain: true,
);

Run _verifyApp(String app) =>
    Run('codesign', ['--verify', '--deep', '--strict', '--verbose=2', app], directory: '.');

/// `0.1.0+1` -> `0.1.0`.
String _marketing(String version) => version.split('+').first;

/// `0.1.0+7` -> `0.1.0.0`: MSIX versions have four parts and the last MUST
/// be zero for Store-compatible packages, so the build number is not used.
String _msixVersion(String version) {
  final parts = _marketing(version).split('.');
  while (parts.length < 3) {
    parts.add('0');
  }
  return [...parts.take(3), '0'].join('.');
}

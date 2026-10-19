// Platform services behind one method channel: hardware device keys, the app
// data directory and opening approval links in the system browser. Linux,
// used for testing, implements the same services in Dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../features/preferences.dart';
import '../features/lock/app_lock_controller.dart';

/// The channel the iOS and Android runners implement (`MilaPlatform`).
const MethodChannel milaPlatformChannel = MethodChannel('dev.overalls.mila/platform');

/// A key in the Secure Enclave (iOS) or StrongBox/Keystore (Android). The
/// private half never crosses the channel: only the public point and DER
/// signatures do.
final class HardwareDeviceKey implements DeviceKey {
  HardwareDeviceKey._(this._host, this.publicBlob);

  final String _host;

  @override
  final Uint8List publicBlob;

  @override
  Future<Uint8List> sign(Uint8List data) async {
    final der = await milaPlatformChannel.invokeMethod<Uint8List>('deviceKey.sign', {
      'host': _host,
      'data': data,
    });
    final signature = der == null ? null : decodeDerSignature(der);
    if (signature == null) throw const FormatException('keystore returned a malformed signature');
    return p256SignatureBlob(signature.$1, signature.$2);
  }
}

final class HardwareDeviceKeyStore implements DeviceKeyStore {
  const HardwareDeviceKeyStore();

  @override
  Future<DeviceKey> keyFor(String host) async {
    if (!isHostname(host)) throw ArgumentError.value(host, 'host', 'not a hostname');
    final point = await milaPlatformChannel.invokeMethod<Uint8List>('deviceKey.public', {
      'host': host,
    });
    if (point == null) throw const FormatException('keystore returned no public key');
    return HardwareDeviceKey._(host, p256PublicBlob(point));
  }
}

/// Pinned trust documents as `<host>.json` files, replaced atomically.
final class FileTrustStore implements TrustStore {
  FileTrustStore(this.directory);

  final Directory directory;

  File _file(String host) {
    if (!isHostname(host)) throw ArgumentError.value(host, 'host', 'not a hostname');
    return File('${directory.path}/$host.json');
  }

  @override
  Future<TrustDocument?> read(String host) async {
    final file = _file(host);
    if (!await file.exists()) return null;
    // A pin is re-validated like a fetched document, but never retired here:
    // resolveTrust decides whether a retired pin may still be used.
    final (document, _) = decodeTrustDocument(await file.readAsBytes(), originHost: host, now: 0);
    return document;
  }

  @override
  Future<void> write(String host, TrustDocument document) async {
    await directory.create(recursive: true);
    final file = _file(host);
    final staging = File('${file.path}.new');
    await staging.writeAsString(jsonEncode(document.toJson()), flush: true);
    await staging.rename(file.path);
  }
}

/// Where Mila keeps device keys (Linux) and pinned trust.
Future<Directory> milaDataDirectory() async {
  if (Platform.isLinux) {
    final env = Platform.environment;
    final base = env['XDG_DATA_HOME'] ?? '${env['HOME']}/.local/share';
    return Directory('$base/dev.overalls.mila');
  }
  final path = await milaPlatformChannel.invokeMethod<String>('dataDirectory');
  if (path == null) throw StateError('platform returned no data directory');
  return Directory(path);
}

/// Opens an approval link in the system browser. Only HTTPS is opened, so a
/// reply cannot make Mila launch another scheme's handler.
Future<void> openApprovalLink(Uri uri) async {
  if (uri.scheme != 'https' || !isHostname(uri.host)) {
    throw ArgumentError.value(uri.scheme, 'uri', 'approval links are HTTPS');
  }
  if (Platform.isLinux) {
    // The URL is one argument: no shell parses it.
    await Process.run('xdg-open', [uri.toString()]);
    return;
  }
  await milaPlatformChannel.invokeMethod<void>('openUrl', {'url': uri.toString()});
}

/// Calls the platform makes into Dart, fanned out by method name.
final StreamController<MethodCall> _platformCalls = StreamController<MethodCall>.broadcast();
bool _listening = false;

Stream<MethodCall> _calls() {
  if (!_listening) {
    _listening = true;
    milaPlatformChannel.setMethodCallHandler((call) async => _platformCalls.add(call));
  }
  return _platformCalls.stream;
}

/// `overalls://` links from the platform. Linux receives the first as a
/// launch argument from its `x-scheme-handler/overalls` desktop entry and
/// later ones from a second `mila` invocation, which the single-instance
/// runner forwards over the channel; iOS and Android push them over the
/// channel too, holding the launch link until asked.
Stream<String> platformLinks(List<String> arguments) {
  bool isLink(Object? value) => value is String && value.startsWith('overalls://');
  final links = StreamController<String>();
  _calls().listen((call) {
    if (call.method == 'link' && isLink(call.arguments)) links.add(call.arguments as String);
  });
  if (Platform.isLinux) {
    arguments.where(isLink).forEach(links.add);
    return links.stream;
  }
  unawaited(
    milaPlatformChannel.invokeMethod<String>('link.initial').then((link) {
      if (isLink(link)) links.add(link!);
    }),
  );
  return links.stream;
}

/// Poke keys in the Keychain (iOS) or Keystore-wrapped storage (Android),
/// where the notification extension can open pokes. Only public keys cross.
final class HardwarePokeKeyStore implements PokeKeyStore {
  const HardwarePokeKeyStore();

  @override
  Future<Uint8List> publicKeyFor(String host) async {
    if (!isHostname(host)) throw ArgumentError.value(host, 'host', 'not a hostname');
    final public = await milaPlatformChannel.invokeMethod<Uint8List>('pokeKey.public', {
      'host': host,
    });
    if (public == null || public.length != 32) {
      throw const FormatException('platform returned no poke public key');
    }
    return public;
  }

  @override
  Future<void> delete(String host) async {
    if (!isHostname(host)) throw ArgumentError.value(host, 'host', 'not a hostname');
    await milaPlatformChannel.invokeMethod<void>('pokeKey.delete', {'host': host});
  }
}

/// APNs (iOS) or FCM (Android) through the platform channel.
final class ChannelPushPlatform implements PushPlatform {
  ChannelPushPlatform(this.provider);

  @override
  final PushProvider provider;

  @override
  Future<PushEnvironment> environment() async {
    final value = await milaPlatformChannel.invokeMethod<String>('push.environment');
    return PushEnvironment.fromWire(value) ?? PushEnvironment.production;
  }

  @override
  Future<String> token() async {
    final String? token;
    try {
      token = await milaPlatformChannel.invokeMethod<String>('push.token');
    } on PlatformException catch (e) {
      if (e.code == 'permission_denied') throw const PushPermissionDeniedException();
      throw const PushUnavailableException();
    } on MissingPluginException {
      throw const PushUnavailableException();
    }
    if (token == null || token.isEmpty || token.length > 4096) {
      throw const PushUnavailableException();
    }
    return token;
  }

  @override
  Stream<String> get tokenChanges => _calls()
      .where((call) => call.method == 'push.tokenChanged' && call.arguments is String)
      .map((call) => call.arguments as String);
}

/// The push service for this platform, or null where there is none (Linux).
PushPlatform? platformPush() => Platform.isIOS
    ? ChannelPushPlatform(PushProvider.apns)
    : Platform.isAndroid
    ? ChannelPushPlatform(PushProvider.fcm)
    : null;

/// Biometrics or the device passcode through `local_auth`. Linux has no
/// implementation, so the lock is unavailable there.
final class PlatformLockAuthenticator implements LockAuthenticator {
  PlatformLockAuthenticator() : _auth = LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<LockAvailability> availability() async {
    if (!Platform.isIOS && !Platform.isAndroid) return LockAvailability.unavailable;
    try {
      return await _auth.isDeviceSupported()
          ? LockAvailability.available
          : LockAvailability.unavailable;
    } on PlatformException {
      return LockAvailability.unavailable;
    } on MissingPluginException {
      return LockAvailability.unavailable;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, persistAcrossBackgrounding: true);
    } on LocalAuthException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

/// Mila's settings and push records as one owner-only JSON file.
final class FilePreferences implements PreferencesStore {
  FilePreferences(this.directory);

  final Directory directory;

  File get _file => File('${directory.path}/preferences.json');

  @override
  Future<Map<String, Object?>> read() async {
    try {
      final bytes = await readOwnerOnly(_file);
      if (bytes == null || bytes.length > 65536) return const {};
      final value = jsonDecode(utf8.decode(bytes));
      return value is Map<String, Object?> ? value : const {};
    } on FileSystemException {
      return const {};
    } on FormatException {
      return const {};
    }
  }

  @override
  Future<void> write(Map<String, Object?> values) async {
    await writeOwnerOnly(directory, 'preferences.json', utf8.encode(jsonEncode(values)));
  }
}

/// The production connector for this platform.
Future<SshPorscheConnector> platformConnector() async {
  final data = await milaDataDirectory();
  return SshPorscheConnector(
    keys: Platform.isLinux
        ? FileDeviceKeyStore(Directory('${data.path}/device-keys'))
        : const HardwareDeviceKeyStore(),
    trust: FileTrustStore(Directory('${data.path}/trust')),
    fetch: fetchTrustDocument,
    clock: () => DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );
}

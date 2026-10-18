// Platform services behind one method channel: hardware device keys, the app
// data directory and opening approval links in the system browser. Linux,
// used for testing, implements the same services in Dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

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

/// `overalls://` links from the platform. Linux receives them as launch
/// arguments from its `x-scheme-handler/overalls` desktop entry; iOS and
/// Android push them over the channel, holding the launch link until asked.
Stream<String> platformLinks(List<String> arguments) {
  bool isLink(Object? value) => value is String && value.startsWith('overalls://');
  if (Platform.isLinux) return Stream.fromIterable(arguments.where(isLink));
  final links = StreamController<String>();
  milaPlatformChannel.setMethodCallHandler((call) async {
    if (call.method == 'link' && isLink(call.arguments)) links.add(call.arguments as String);
  });
  unawaited(
    milaPlatformChannel.invokeMethod<String>('link.initial').then((link) {
      if (isLink(link)) links.add(link!);
    }),
  );
  return links.stream;
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

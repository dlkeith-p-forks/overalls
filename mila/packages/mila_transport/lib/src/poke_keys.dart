// The device's X25519 poke keys: one per deployment, like the SSH device
// key, so deployments cannot link one device's registrations. On iOS and
// Android the private half lives in platform storage the notification
// extension can read; only the public key reaches Dart. Linux, which has no
// push service, keeps an owner-only file for tests and tools.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mila_core/mila_core.dart';

import 'owner_only.dart';

// @cc [owner:ghuntley,label:security] mila-poke-key-custody
// Each deployment MUST get its own X25519 poke key. Only the public key may
// leave platform custody (to `device register --enc-pubkey`); private poke
// keys MUST NOT cross the platform channel, be logged or enter a snapshot.
/// Finds, creates and deletes the poke key Mila registers for one host.
abstract interface class PokeKeyStore {
  /// The host's poke public key, creating the key pair on first use.
  Future<Uint8List> publicKeyFor(String host);

  /// Forgets the host's poke key; later pokes for it can no longer open.
  Future<void> delete(String host);
}

/// Poke keys as owner-only `<host>.json` files under [directory].
final class FilePokeKeyStore implements PokeKeyStore {
  FilePokeKeyStore(this.directory, {Random? random}) : _random = random ?? Random.secure();

  final Directory directory;
  final Random _random;

  File _file(String host) {
    if (!isHostname(host)) throw ArgumentError.value(host, 'host', 'not a hostname');
    return File('${directory.path}/$host.json');
  }

  /// The full key pair, for opening pokes in-process (tests and tools).
  Future<PokeKeyPair> keyPairFor(String host) async {
    final file = _file(host);
    final existing = await readOwnerOnly(file);
    if (existing != null) {
      final keys = _decode(existing);
      if (keys == null) throw FileSystemException('poke key is malformed', file.path);
      return keys;
    }
    final keys = PokeKeyPair.generate(_random);
    await writeOwnerOnly(
      directory,
      '$host.json',
      utf8.encode(jsonEncode({'version': 1, 'private': encodeBase64UrlUnpadded(keys.privateKey)})),
    );
    return keys;
  }

  @override
  Future<Uint8List> publicKeyFor(String host) async => (await keyPairFor(host)).publicKey;

  @override
  Future<void> delete(String host) async {
    final file = _file(host);
    if (await file.exists()) await file.delete();
  }

  static PokeKeyPair? _decode(List<int> bytes) {
    final Object? value;
    try {
      value = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
    if (value is! Map<String, Object?> || value.length != 2 || value['version'] != 1) return null;
    final private = value['private'];
    final raw = private is String ? decodeBase64UrlUnpadded(private) : null;
    return raw == null ? null : PokeKeyPair.fromPrivate(raw);
  }
}

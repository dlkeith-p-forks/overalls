/// The account's approved SSH keys as `ssh-key list --json` reports them, and
/// the `ssh-key remove` change Mila sends. Marshall decides whose keys may be
/// listed or revoked; Mila only shows and asks.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

import 'app_route.dart';
import 'ssh_command.dart';

/// One approved key. Its public key is never part of the listing.
final class SshKeyEntry {
  const SshKeyEntry({
    required this.id,
    required this.label,
    required this.algorithm,
    required this.fingerprint,
    this.addedAt,
  });

  final String id;

  /// A display name, possibly empty.
  final String label;
  final String algorithm;

  /// `SHA256:` and the unpadded base64 digest of the key blob.
  final String fingerprint;
  final DateTime? addedAt;
}

/// One decoded listing.
final class SshKeyListing {
  const SshKeyListing({required this.keys, this.skipped = 0});

  final List<SshKeyEntry> keys;

  /// Rows refused by strict decoding.
  final int skipped;
}

/// Why a key listing could not be decoded.
final class SshKeyFormatException implements Exception {
  const SshKeyFormatException(this.field);
  final String field;
  @override
  String toString() => 'SshKeyFormatException($field)';
}

final RegExp _fingerprint = RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$');
final RegExp _printable = RegExp(r'^[^\x00-\x1f\x7f\x80-\x9f]*$');

/// Decodes `ssh-key list --json`: `keys` is required; a row with a bad id,
/// algorithm, fingerprint or label is skipped and counted.
SshKeyListing decodeSshKeyListing(Map<String, Object?> result) {
  final items = result['keys'];
  if (items is! List<Object?>) throw const SshKeyFormatException('keys');
  final keys = <SshKeyEntry>[];
  var skipped = 0;
  for (final item in items) {
    if (item is! Map<String, Object?>) {
      skipped++;
      continue;
    }
    final id = item['id'];
    final label = item['label'] ?? '';
    final algorithm = item['algorithm'];
    final fingerprint = item['fingerprint'];
    final inserted = item['inserted_at'];
    if (id is! String ||
        !isCanonicalUuid(id) ||
        label is! String ||
        label.length > 128 ||
        !_printable.hasMatch(label) ||
        algorithm is! String ||
        algorithm.isEmpty ||
        algorithm.length > 64 ||
        !_printable.hasMatch(algorithm) ||
        fingerprint is! String ||
        !_fingerprint.hasMatch(fingerprint)) {
      skipped++;
      continue;
    }
    keys.add(
      SshKeyEntry(
        id: id,
        label: label,
        algorithm: algorithm,
        fingerprint: fingerprint,
        addedAt: inserted is String ? DateTime.tryParse(inserted) : null,
      ),
    );
  }
  return SshKeyListing(keys: List.unmodifiable(keys), skipped: skipped);
}

/// The OpenSSH SHA-256 fingerprint of an `algorithm base64 [comment]` public
/// key, as Marshall computes it, or null when [publicKey] is not one.
String? sshFingerprint(String publicKey) {
  final parts = publicKey.trim().split(RegExp(r'[ \t]+'));
  if (parts.length < 2) return null;
  final List<int> blob;
  try {
    blob = base64.decode(parts[1]);
  } on FormatException {
    return null;
  }
  final digest = SHA256Digest().process(Uint8List.fromList(blob));
  return 'SHA256:${base64.encode(digest).replaceAll('=', '')}';
}

/// `ssh-key list --json`.
PorscheCommand sshKeyListCommand() => PorscheCommand('ssh-key list', options: const {'json': true});

/// `ssh-key remove`, or null when [keyId] would be refused.
PorscheCommand? sshKeyRemoveCommand(String keyId, {required String requestId}) {
  final command = PorscheCommand(
    'ssh-key remove',
    arguments: [keyId],
    options: {'json': true, 'request-id': requestId},
  );
  return validateCommand(command) == null ? command : null;
}

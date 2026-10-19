/// Strict SSH host trust for Porsche connections (ADR-0228).
///
/// A port of `OverallsProtocol.SSHHostCertificate` parsing and verification
/// and of Lyra's `ssh-trust.json` policy. Mila trusts a host only when it
/// presents an Ed25519 host certificate signed by the deployment's published
/// CA for the exact management host. There is no trust-on-first-use and no
/// unsigned fallback.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pinenacl/ed25519.dart' as ed;

import 'app_route.dart' show isHostname;

/// The only host key algorithm Mila accepts from Porsche.
const String hostCertificateAlgorithm = 'ssh-ed25519-cert-v01@openssh.com';
const int _maximumLine = 16384;
const int _maxInt = 0x7fffffffffffffff;

/// A parsed, not yet verified, host certificate.
final class HostCertificate {
  const HostCertificate._({
    required this.publicKey,
    required this.ca,
    required this.principals,
    required this.serial,
    required this.validAfter,
    required this.validBefore,
    required this.keyId,
    required this.signed,
    required this.signature,
  });

  /// Raw 32-byte Ed25519 leaf key.
  final Uint8List publicKey;

  /// The CA as an `ssh-ed25519 BASE64` line.
  final String ca;
  final List<String> principals;
  final int serial;

  /// Seconds since the epoch; [validAfter] inclusive, [validBefore] exclusive.
  final int validAfter;
  final int validBefore;
  final String keyId;
  final Uint8List signed;
  final Uint8List signature;
}

final class _Reader {
  _Reader(this.bytes);
  final Uint8List bytes;
  int offset = 0;

  bool get done => offset == bytes.length;

  Uint8List? field() {
    final length = uint32();
    if (length == null || offset + length > bytes.length) return null;
    final value = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return value;
  }

  int? uint32() {
    if (offset + 4 > bytes.length) return null;
    final value = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
    offset += 4;
    return value;
  }

  /// Reads a uint64. Dart ints are signed 64-bit, so values at or above 2^63
  /// saturate (OpenSSH writes 2^64-1 for "forever") rather than wrap.
  int? uint64() {
    if (offset + 8 > bytes.length) return null;
    final data = ByteData.sublistView(bytes, offset, offset + 8);
    offset += 8;
    final high = data.getUint32(0);
    if (high >= 0x80000000) return _maxInt;
    return high * 0x100000000 + data.getUint32(4);
  }
}

Uint8List _string(List<int> value) {
  final out = BytesBuilder(copy: false)
    ..add((ByteData(4)..setUint32(0, value.length)).buffer.asUint8List())
    ..add(value);
  return out.toBytes();
}

String? _utf8(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

bool _equals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Encodes a raw Ed25519 key as an `ssh-ed25519 BASE64` line.
String ed25519KeyLine(List<int> raw) =>
    'ssh-ed25519 ${base64.encode(_string(utf8.encode('ssh-ed25519')) + _string(raw))}';

/// Decodes a canonical `ssh-ed25519 BASE64` line to its raw key, or null.
Uint8List? ed25519FromLine(String line) {
  final parts = line.split(' ');
  if (parts.length != 2 || parts[0] != 'ssh-ed25519') return null;
  final Uint8List blob;
  try {
    blob = base64.decode(parts[1]);
  } on FormatException {
    return null;
  }
  if (base64.encode(blob) != parts[1]) return null;
  final reader = _Reader(blob);
  final algorithm = reader.field();
  final key = reader.field();
  if (algorithm == null || key == null || !reader.done) return null;
  if (_utf8(algorithm) != 'ssh-ed25519' || key.length != 32) return null;
  return Uint8List.fromList(key);
}

/// Parses a host certificate from its wire blob, as the SSH handshake
/// delivers it. Returns null for anything outside the closed format.
HostCertificate? parseHostCertificateBlob(Uint8List blob) {
  if (blob.length > _maximumLine) return null;
  final reader = _Reader(blob);
  final algorithm = reader.field();
  if (algorithm == null || _utf8(algorithm) != hostCertificateAlgorithm) return null;
  final nonce = reader.field();
  if (nonce == null || nonce.length < 16 || nonce.length > 64) return null;
  final key = reader.field();
  if (key == null || key.length != 32) return null;
  final serial = reader.uint64();
  if (serial == null || reader.uint32() != 2) return null;
  final idBytes = reader.field();
  final id = idBytes == null ? null : _utf8(idBytes);
  if (id == null || idBytes!.isEmpty || idBytes.length > 128) return null;
  final names = reader.field();
  if (names == null) return null;
  final principals = _principals(names);
  if (principals == null) return null;
  final after = reader.uint64();
  final before = reader.uint64();
  if (after == null || before == null || after >= before) return null;
  for (var i = 0; i < 3; i++) {
    final empty = reader.field();
    if (empty == null || empty.isNotEmpty) return null;
  }
  final caBlob = reader.field();
  if (caBlob == null) return null;
  final caLine = 'ssh-ed25519 ${base64.encode(caBlob)}';
  if (ed25519FromLine(caLine) == null) return null;
  final signedLength = reader.offset;
  final signatureField = reader.field();
  if (signatureField == null || !reader.done) return null;
  final signatureReader = _Reader(signatureField);
  final signatureAlgorithm = signatureReader.field();
  final signature = signatureReader.field();
  if (signatureAlgorithm == null || signature == null || !signatureReader.done) return null;
  if (_utf8(signatureAlgorithm) != 'ssh-ed25519' || signature.length != 64) return null;
  return HostCertificate._(
    publicKey: Uint8List.fromList(key),
    ca: caLine,
    principals: List.unmodifiable(principals),
    serial: serial,
    validAfter: after,
    validBefore: before,
    keyId: id,
    signed: Uint8List.fromList(Uint8List.sublistView(blob, 0, signedLength)),
    signature: Uint8List.fromList(signature),
  );
}

/// Parses an OpenSSH certificate line (`ALGORITHM BASE64 [COMMENT]`).
HostCertificate? parseHostCertificateLine(String line) {
  if (utf8.encode(line).length > _maximumLine) return null;
  final parts = line.trim().split(RegExp(r'[ \t]+'));
  if (parts.length < 2 || parts[0] != hostCertificateAlgorithm) return null;
  final Uint8List blob;
  try {
    blob = base64.decode(parts[1]);
  } on FormatException {
    return null;
  }
  if (base64.encode(blob) != parts[1]) return null;
  return parseHostCertificateBlob(blob);
}

List<String>? _principals(Uint8List bytes) {
  final reader = _Reader(bytes);
  final names = <String>[];
  while (!reader.done) {
    if (names.length >= 8) return null;
    final field = reader.field();
    final name = field == null ? null : _utf8(field);
    if (name == null || !isHostname(name) || names.contains(name)) return null;
    names.add(name);
  }
  return names.isEmpty ? null : names;
}

/// Why a presented host key was refused.
enum HostRefusal { malformed, wrongAuthority, wrongPrincipal, notYetValid, expired, badSignature }

/// Verifies [cert] against the trusted [ca] line for [principal] at [now]
/// (seconds since the epoch). Returns null when trusted.
HostRefusal? verifyHostCertificate(
  HostCertificate cert, {
  required String ca,
  required String principal,
  required int now,
}) {
  final rawCa = ed25519FromLine(ca);
  if (rawCa == null) return HostRefusal.malformed;
  if (cert.ca != ca) return HostRefusal.wrongAuthority;
  if (!cert.principals.contains(principal)) return HostRefusal.wrongPrincipal;
  if (now < cert.validAfter) return HostRefusal.notYetValid;
  if (now >= cert.validBefore) return HostRefusal.expired;
  try {
    ed.VerifyKey(rawCa).verify(signature: ed.Signature(cert.signature), message: cert.signed);
  } on Exception {
    return HostRefusal.badSignature;
  }
  return null;
}

/// A deployment's published SSH trust policy (`/bin/ssh-trust.json`).
final class TrustDocument {
  const TrustDocument({
    required this.ca,
    required this.managementHost,
    required this.zone,
    required this.retirement,
  });

  final String ca;
  final String managementHost;
  final String zone;

  /// Seconds since the epoch after which the policy must be refetched.
  final int retirement;

  Map<String, Object?> toJson() => {
    'version': 1,
    'ca': ca,
    'management_host': managementHost,
    'zone': zone,
    'retirement': retirement,
  };

  /// Whether [other] names the same authority. A deployment never silently
  /// changes CA, host or zone; a mismatch must be reconciled explicitly.
  bool sameAuthority(TrustDocument other) =>
      other.ca == ca && other.managementHost == managementHost && other.zone == zone;
}

/// Why a trust document was refused.
enum TrustRefusal { malformed, wrongHost, retired, conflicts }

const int _maximumTrustBytes = 8192;

/// Decodes and validates a trust document fetched over HTTPS from
/// [originHost], at [now] seconds since the epoch.
(TrustDocument?, TrustRefusal?) decodeTrustDocument(
  List<int> bytes, {
  required String originHost,
  required int now,
}) {
  if (bytes.length > _maximumTrustBytes) return (null, TrustRefusal.malformed);
  final Object? value;
  try {
    value = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return (null, TrustRefusal.malformed);
  }
  if (value is! Map<String, Object?>) return (null, TrustRefusal.malformed);
  const keys = {'version', 'ca', 'management_host', 'zone', 'retirement'};
  if (value.length != keys.length || !value.keys.every(keys.contains)) {
    return (null, TrustRefusal.malformed);
  }
  final ca = value['ca'];
  final host = value['management_host'];
  final zone = value['zone'];
  final retirement = value['retirement'];
  if (value['version'] != 1 ||
      ca is! String ||
      ed25519FromLine(ca) == null ||
      host is! String ||
      !isHostname(host) ||
      host.length > 180 ||
      zone is! String ||
      !isHostname(zone) ||
      zone.length > 189 ||
      retirement is! int ||
      retirement < 0) {
    return (null, TrustRefusal.malformed);
  }
  if (host != originHost) return (null, TrustRefusal.wrongHost);
  if (retirement <= now) return (null, TrustRefusal.retired);
  return (TrustDocument(ca: ca, managementHost: host, zone: zone, retirement: retirement), null);
}

/// Decides whether a freshly fetched [fetched] document may replace the
/// [pinned] one Mila already holds for a deployment.
(TrustDocument?, TrustRefusal?) reconcileTrust(TrustDocument? pinned, TrustDocument fetched) {
  if (pinned == null) return (fetched, null);
  if (!pinned.sameAuthority(fetched)) return (null, TrustRefusal.conflicts);
  return (fetched.retirement >= pinned.retirement ? fetched : pinned, null);
}

/// Issues a host certificate, as `SSHHostCertificate.issue/8`. Test support
/// for fixtures and fakes; Mila never holds a CA in production.
Uint8List issueHostCertificate({
  required List<int> leaf,
  required List<int> caSeed,
  required List<int> nonce,
  required List<String> principals,
  required int serial,
  required String keyId,
  required int validAfter,
  required int validBefore,
}) {
  final signer = ed.SigningKey.fromSeed(Uint8List.fromList(caSeed));
  final caRaw = signer.verifyKey.asTypedList;
  final caBlob = _string(utf8.encode('ssh-ed25519')) + _string(caRaw);
  Uint8List u64(int value) => (ByteData(8)..setUint64(0, value)).buffer.asUint8List();
  final signed = BytesBuilder(copy: false)
    ..add(_string(utf8.encode(hostCertificateAlgorithm)))
    ..add(_string(nonce))
    ..add(_string(leaf))
    ..add(u64(serial))
    ..add((ByteData(4)..setUint32(0, 2)).buffer.asUint8List())
    ..add(_string(utf8.encode(keyId)))
    ..add(_string([for (final name in principals) ..._string(utf8.encode(name))]))
    ..add(u64(validAfter))
    ..add(u64(validBefore))
    ..add(_string(const []))
    ..add(_string(const []))
    ..add(_string(const []))
    ..add(_string(caBlob));
  final body = signed.toBytes();
  final signature = signer.sign(body).signature.asTypedList;
  return Uint8List.fromList(
    body + _string(_string(utf8.encode('ssh-ed25519')) + _string(signature)),
  );
}

/// Constant-time comparison for key material.
bool keyBytesEqual(List<int> a, List<int> b) => _equals(a, b);

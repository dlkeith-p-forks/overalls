// The device's SSH identity: one P-256 key per deployment (ADR-0220). On iOS
// and Android the private key never leaves the Secure Enclave or StrongBox;
// Linux, used for testing, keeps a software key in a 0600 file. Separate
// keys per deployment keep deployments from linking one device's sessions.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pointycastle/export.dart';

/// The SSH algorithm of every Mila device key.
const String deviceKeyAlgorithm = 'ecdsa-sha2-nistp256';

/// A P-256 key whose private half is held by platform custody.
abstract interface class DeviceKey {
  /// The SSH public key blob (`ecdsa-sha2-nistp256`, `nistp256`, point).
  Uint8List get publicBlob;

  /// Signs [data] with ECDSA over SHA-256, returning the SSH signature blob.
  Future<Uint8List> sign(Uint8List data);
}

/// Finds or creates the key Mila uses for one deployment host.
abstract interface class DeviceKeyStore {
  Future<DeviceKey> keyFor(String host);
}

Uint8List _string(List<int> bytes) {
  final out = BytesBuilder(copy: false)
    ..add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List())
    ..add(bytes);
  return out.takeBytes();
}

/// An SSH mpint: minimal big-endian two's complement, positive here.
Uint8List _mpint(BigInt value) {
  assert(!value.isNegative);
  final bytes = <int>[];
  for (var v = value; v > BigInt.zero; v >>= 8) {
    bytes.insert(0, (v & BigInt.from(0xFF)).toInt());
  }
  if (bytes.isNotEmpty && bytes.first & 0x80 != 0) bytes.insert(0, 0);
  return _string(bytes);
}

/// The SSH public key blob for an uncompressed P-256 [point].
Uint8List p256PublicBlob(List<int> point) {
  if (point.length != 65 || point.first != 4) {
    throw ArgumentError.value(point.length, 'point', 'not an uncompressed P-256 point');
  }
  return Uint8List.fromList([
    ..._string(utf8.encode(deviceKeyAlgorithm)),
    ..._string(utf8.encode('nistp256')),
    ..._string(point),
  ]);
}

/// The SSH signature blob for an ECDSA signature `(r, s)`.
Uint8List p256SignatureBlob(BigInt r, BigInt s) => Uint8List.fromList([
  ..._string(utf8.encode(deviceKeyAlgorithm)),
  ..._string([..._mpint(r), ..._mpint(s)]),
]);

/// An ECDSA signature from a DER `SEQUENCE { INTEGER r, INTEGER s }`, as
/// platform keystores return it. Returns null for anything else.
(BigInt, BigInt)? decodeDerSignature(List<int> der) {
  var offset = 0;
  int? length() {
    if (offset >= der.length) return null;
    final first = der[offset++];
    if (first < 0x80) return first;
    if (first != 0x81 || offset >= der.length) return null;
    return der[offset++];
  }

  BigInt? integer() {
    if (offset >= der.length || der[offset++] != 0x02) return null;
    final size = length();
    if (size == null || size == 0 || size > 33 || offset + size > der.length) return null;
    final bytes = der.sublist(offset, offset + size);
    offset += size;
    if (bytes.first & 0x80 != 0) return null;
    return bytes.fold<BigInt>(BigInt.zero, (value, byte) => (value << 8) | BigInt.from(byte));
  }

  if (der.isEmpty || der[offset++] != 0x30) return null;
  final total = length();
  if (total == null || offset + total != der.length) return null;
  final r = integer();
  final s = integer();
  if (r == null || s == null || offset != der.length) return null;
  return (r, s);
}

final ECDomainParameters _p256 = ECCurve_secp256r1();

/// A software P-256 key. Linux only: mobile keys live in hardware custody.
final class SoftwareDeviceKey implements DeviceKey {
  SoftwareDeviceKey._(this._private) {
    final point = (_p256.G * _private)!;
    publicBlob = p256PublicBlob(point.getEncoded(false));
  }

  /// A key from its 32-byte private scalar; null when out of range.
  static SoftwareDeviceKey? fromScalar(List<int> scalar) {
    if (scalar.length != 32) return null;
    final d = scalar.fold<BigInt>(BigInt.zero, (v, b) => (v << 8) | BigInt.from(b));
    if (d == BigInt.zero || d >= _p256.n) return null;
    return SoftwareDeviceKey._(d);
  }

  /// A fresh key from [random], which must be cryptographically secure.
  static (SoftwareDeviceKey, Uint8List) generate(Random random) {
    while (true) {
      final scalar = Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
      final key = fromScalar(scalar);
      if (key != null) return (key, scalar);
    }
  }

  final BigInt _private;

  @override
  late final Uint8List publicBlob;

  @override
  Future<Uint8List> sign(Uint8List data) async {
    // RFC 6979 deterministic nonces: no randomness is needed to sign.
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(_private, _p256)));
    final signature = signer.generateSignature(data) as ECSignature;
    return p256SignatureBlob(signature.r, signature.s);
  }
}

/// Software keys under [directory], one `<host>.json` file each, created
/// owner-only before any private byte is written.
final class FileDeviceKeyStore implements DeviceKeyStore {
  FileDeviceKeyStore(this.directory, {Random? random}) : _random = random ?? Random.secure();

  final Directory directory;
  final Random _random;

  @override
  Future<DeviceKey> keyFor(String host) async {
    final file = File('${directory.path}/$host.json');
    if (await file.exists()) {
      if (((await file.stat()).mode & 0x3F) != 0) {
        throw const FileSystemException('device key is readable by other users');
      }
      final key = _decode(await file.readAsBytes());
      if (key == null) throw const FileSystemException('device key is malformed');
      return key;
    }
    await directory.create(recursive: true);
    _chmod(directory.path, 0x1C0); // 0700
    final staging = File('${file.path}.new');
    if (await staging.exists()) await staging.delete();
    await staging.create(exclusive: true);
    _chmod(staging.path, 0x180); // 0600
    final (key, scalar) = SoftwareDeviceKey.generate(_random);
    await staging.writeAsBytes(
      utf8.encode(jsonEncode({'version': 1, 'scalar': base64.encode(scalar)})),
      flush: true,
    );
    await staging.rename(file.path);
    return key;
  }

  static SoftwareDeviceKey? _decode(List<int> bytes) {
    final Object? value;
    try {
      value = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
    if (value is! Map<String, Object?> || value.length != 2 || value['version'] != 1) return null;
    final scalar = value['scalar'];
    if (scalar is! String) return null;
    try {
      return SoftwareDeviceKey.fromScalar(base64.decode(scalar));
    } on FormatException {
      return null;
    }
  }

  static void _chmod(String path, int mode) {
    final chmod = DynamicLibrary.process()
        .lookupFunction<Int32 Function(Pointer<Utf8>, Uint32), int Function(Pointer<Utf8>, int)>(
          'chmod',
        );
    final native = path.toNativeUtf8();
    try {
      if (chmod(native, mode) != 0) throw FileSystemException('chmod failed', path);
    } finally {
      malloc.free(native);
    }
  }
}

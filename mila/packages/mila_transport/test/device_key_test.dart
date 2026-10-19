import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hegel/hegel.dart';
import 'package:mila_transport/mila_transport.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

/// Reads the SSH `string` fields of [blob], failing on trailing bytes.
List<Uint8List> _fields(Uint8List blob) {
  final data = ByteData.sublistView(blob);
  final fields = <Uint8List>[];
  var offset = 0;
  while (offset < blob.length) {
    final length = data.getUint32(offset);
    fields.add(blob.sublist(offset + 4, offset + 4 + length));
    offset += 4 + length;
  }
  expect(offset, blob.length);
  return fields;
}

BigInt _unsigned(List<int> bytes) =>
    bytes.fold<BigInt>(BigInt.zero, (v, b) => (v << 8) | BigInt.from(b));

List<int> _derInteger(BigInt value) {
  final bytes = <int>[];
  for (var v = value; v > BigInt.zero; v >>= 8) {
    bytes.insert(0, (v & BigInt.from(0xFF)).toInt());
  }
  if (bytes.isEmpty || bytes.first & 0x80 != 0) bytes.insert(0, 0);
  return [0x02, bytes.length, ...bytes];
}

/// Verifies an SSH P-256 signature blob with an independent verifier.
bool _verifies(Uint8List publicBlob, Uint8List data, Uint8List signatureBlob) {
  final curve = ECCurve_secp256r1();
  final point = curve.curve.decodePoint(_fields(publicBlob)[2])!;
  final [type, inner] = _fields(signatureBlob);
  expect(utf8.decode(type), deviceKeyAlgorithm);
  final [r, s] = _fields(inner);
  // mpints are minimal and positive: no redundant leading zero byte.
  for (final m in [r, s]) {
    expect(m.first != 0 || m[1] & 0x80 != 0, isTrue);
  }
  final verifier = ECDSASigner(SHA256Digest())
    ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(point, curve)));
  return verifier.verifySignature(data, ECSignature(_unsigned(r), _unsigned(s)));
}

void main() {
  test('the public blob is the OpenSSH ecdsa-sha2-nistp256 encoding', () {
    final (key, _) = SoftwareDeviceKey.generate(Random(1));
    final [type, curve, point] = _fields(key.publicBlob);
    expect(utf8.decode(type), 'ecdsa-sha2-nistp256');
    expect(utf8.decode(curve), 'nistp256');
    expect(point, hasLength(65));
    expect(point.first, 4);
  });

  property('device signatures verify over the signed data and nothing else', (tc) async {
    final seed = tc.draw(integers(min: 0, max: 1 << 30));
    final data = Uint8List.fromList(tc.draw(lists(integers(min: 0, max: 255), maxLength: 256)));
    final (key, scalar) = SoftwareDeviceKey.generate(Random(seed));
    final signature = await key.sign(data);
    expect(_verifies(key.publicBlob, data, signature), isTrue);
    expect(_verifies(key.publicBlob, Uint8List.fromList([...data, 0]), signature), isFalse);
    // The scalar alone reproduces the key.
    expect(SoftwareDeviceKey.fromScalar(scalar)!.publicBlob, key.publicBlob);
  });

  property('keystore DER signatures decode exactly and malformed DER is refused', (tc) {
    final n = ECCurve_secp256r1().n;
    BigInt draw() =>
        BigInt.parse(tc.draw(fromRegex(r'[1-9][0-9]{0,76}', fullMatch: true))) % n + BigInt.one;
    final r = draw(), s = draw();
    final body = [..._derInteger(r), ..._derInteger(s)];
    final der = [0x30, body.length, ...body];
    expect(decodeDerSignature(der), (r, s));
    final cut = tc.draw(integers(min: 0, max: der.length - 1));
    expect(decodeDerSignature(der.sublist(0, cut)), isNull);
    expect(decodeDerSignature([...der, 0]), isNull);
  });

  test('scalars outside the curve order are refused', () {
    expect(SoftwareDeviceKey.fromScalar(Uint8List(32)), isNull);
    expect(SoftwareDeviceKey.fromScalar(Uint8List(31)..[0] = 1), isNull);
    expect(SoftwareDeviceKey.fromScalar(Uint8List.fromList(List.filled(32, 0xFF))), isNull);
  });

  group('file custody', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('mila-keys'));
    tearDown(() => root.deleteSync(recursive: true));

    test('a new key file is owner-only and reloads as the same key', () async {
      final store = FileDeviceKeyStore(Directory('${root.path}/keys'), random: Random(7));
      final key = await store.keyFor('overalls.example');
      final file = File('${root.path}/keys/overalls.example.json');
      expect(file.statSync().mode & 0x1FF, 0x180);
      expect(Directory('${root.path}/keys').statSync().mode & 0x1FF, 0x1C0);
      final again = await FileDeviceKeyStore(
        Directory('${root.path}/keys'),
      ).keyFor('overalls.example');
      expect(again.publicBlob, key.publicBlob);
      final other = await store.keyFor('other.example');
      expect(other.publicBlob, isNot(key.publicBlob));
    });

    test('a key file other users can read is refused, not used', () async {
      final store = FileDeviceKeyStore(Directory(root.path), random: Random(7));
      await store.keyFor('overalls.example');
      final file = File('${root.path}/overalls.example.json');
      await Process.run('chmod', ['0644', file.path]);
      expect(store.keyFor('overalls.example'), throwsA(isA<FileSystemException>()));
    });

    test('a malformed key file is refused', () async {
      File('${root.path}/overalls.example.json').writeAsStringSync('{"version":1,"scalar":"AA=="}');
      await Process.run('chmod', ['0600', '${root.path}/overalls.example.json']);
      expect(
        FileDeviceKeyStore(Directory(root.path)).keyFor('overalls.example'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}

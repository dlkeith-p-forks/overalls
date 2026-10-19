import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hegel/hegel.dart';
import 'package:mila_core/src/host_trust.dart';
import 'package:pinenacl/ed25519.dart' as ed;
import 'package:test/test.dart';

/// Issued by `OverallsProtocol.SSHHostCertificate.issue/8`.
final File _vectors = File('../../../protocol/test/fixtures/ssh_host_certificates.json');

final Uint8List _caSeed = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
final String _ca = ed25519KeyLine(ed.SigningKey.fromSeed(_caSeed).verifyKey.asTypedList);
final Uint8List _leaf = ed.SigningKey.fromSeed(
  Uint8List.fromList(List<int>.generate(32, (i) => 200 - i)),
).verifyKey.asTypedList;
const String _host = 'overalls.example';
const int _now = 1800000000;

Uint8List _issue({
  List<String> principals = const [_host],
  int after = _now - 60,
  int before = _now + 3600,
  List<int>? caSeed,
}) => issueHostCertificate(
  leaf: _leaf,
  caSeed: caSeed ?? _caSeed,
  nonce: List<int>.filled(32, 7),
  principals: principals,
  serial: 1,
  keyId: 'porsche',
  validAfter: after,
  validBefore: before,
);

List<int> _trustJson(Map<String, Object?> value) => utf8.encode(jsonEncode(value));

Map<String, Object?> _trust({String host = _host, int retirement = _now + 86400}) => {
  'version': 1,
  'ca': _ca,
  'management_host': host,
  'zone': 'apps.overalls.example',
  'retirement': retirement,
};

void main() {
  test('a certificate issued by the CA for the host verifies', () {
    final cert = parseHostCertificateBlob(_issue())!;
    expect(cert.principals, [_host]);
    expect(cert.ca, _ca);
    expect(verifyHostCertificate(cert, ca: _ca, principal: _host, now: _now), isNull);
  });

  test('wrong principal, CA, window or signature is refused with its reason', () {
    final cert = parseHostCertificateBlob(_issue())!;
    expect(
      verifyHostCertificate(cert, ca: _ca, principal: 'evil.example', now: _now),
      HostRefusal.wrongPrincipal,
    );
    expect(
      verifyHostCertificate(cert, ca: _ca, principal: _host, now: _now - 61),
      HostRefusal.notYetValid,
    );
    expect(
      verifyHostCertificate(cert, ca: _ca, principal: _host, now: _now + 3600),
      HostRefusal.expired,
    );
    final otherCa = parseHostCertificateBlob(_issue(caSeed: List<int>.filled(32, 9)))!;
    expect(
      verifyHostCertificate(otherCa, ca: _ca, principal: _host, now: _now),
      HostRefusal.wrongAuthority,
    );
  });

  test('a wildcard principal never matches a concrete host', () {
    // Wildcards are not DNS names, so the closed format refuses them outright.
    expect(parseHostCertificateBlob(_issue(principals: ['*.example'])), isNull);
  });

  test('server-issued certificates verify in Mila', () {
    final document = jsonDecode(_vectors.readAsStringSync()) as Map<String, Object?>;
    for (final entry in (document['certificates']! as List<Object?>).cast<Map<String, Object?>>()) {
      final cert = parseHostCertificateLine(entry['line']! as String);
      expect(cert, isNotNull);
      expect(ed25519KeyLine(cert!.publicKey), entry['leaf']);
      expect(
        verifyHostCertificate(
          cert,
          ca: entry['ca']! as String,
          principal: entry['principal']! as String,
          now: entry['now']! as int,
        ),
        entry['valid'] == true ? isNull : isNotNull,
      );
    }
  });

  property('flipping any certificate byte never yields a trusted certificate', (tc) {
    final blob = _issue();
    final index = tc.draw(integers(min: 0, max: blob.length - 1), name: 'index');
    final flip = tc.draw(integers(min: 1, max: 255), name: 'flip');
    final mutated = Uint8List.fromList(blob)..[index] ^= flip;
    final cert = parseHostCertificateBlob(mutated);
    if (cert != null) {
      expect(verifyHostCertificate(cert, ca: _ca, principal: _host, now: _now), isNotNull);
    }
  });

  property('truncated or extended blobs never parse', (tc) {
    final blob = _issue();
    final cut = tc.draw(integers(min: 0, max: blob.length - 1), name: 'cut');
    expect(parseHostCertificateBlob(Uint8List.sublistView(blob, 0, cut)), isNull);
    final extra = tc.draw(lists(integers(min: 0, max: 255), minLength: 1, maxLength: 8), name: 'x');
    expect(parseHostCertificateBlob(Uint8List.fromList([...blob, ...extra])), isNull);
  });

  property('arbitrary bytes never throw', (tc) {
    final bytes = tc.draw(lists(integers(min: 0, max: 255), maxLength: 300), name: 'bytes');
    parseHostCertificateBlob(Uint8List.fromList(bytes));
    parseHostCertificateLine(String.fromCharCodes(bytes));
  });

  test('the trust document is strict and host-bound', () {
    final (doc, refusal) = decodeTrustDocument(_trustJson(_trust()), originHost: _host, now: _now);
    expect(refusal, isNull);
    expect(doc!.managementHost, _host);
    expect(
      decodeTrustDocument(
        _trustJson(_trust(host: 'other.example')),
        originHost: _host,
        now: _now,
      ).$2,
      TrustRefusal.wrongHost,
    );
    expect(
      decodeTrustDocument(
        _trustJson(_trust(retirement: _now)),
        originHost: _host,
        now: _now,
      ).$2,
      TrustRefusal.retired,
    );
    expect(
      decodeTrustDocument(
        _trustJson({..._trust(), 'extra': true}),
        originHost: _host,
        now: _now,
      ).$2,
      TrustRefusal.malformed,
    );
    expect(
      decodeTrustDocument(List.filled(9000, 32), originHost: _host, now: _now).$2,
      TrustRefusal.malformed,
    );
  });

  property('a pinned authority is never silently replaced', (tc) {
    final pinned = decodeTrustDocument(_trustJson(_trust()), originHost: _host, now: _now).$1!;
    final field = tc.draw(sampledFrom(const ['ca', 'zone', 'retirement', 'none']), name: 'field');
    final changed = switch (field) {
      'ca' => TrustDocument(
        ca: ed25519KeyLine(List<int>.filled(32, 3)),
        managementHost: _host,
        zone: pinned.zone,
        retirement: pinned.retirement,
      ),
      'zone' => TrustDocument(
        ca: pinned.ca,
        managementHost: _host,
        zone: 'other.overalls.example',
        retirement: pinned.retirement,
      ),
      'retirement' => TrustDocument(
        ca: pinned.ca,
        managementHost: _host,
        zone: pinned.zone,
        retirement: pinned.retirement + tc.draw(integers(min: -100, max: 100), name: 'delta'),
      ),
      _ => pinned,
    };
    final (kept, refusal) = reconcileTrust(pinned, changed);
    if (field == 'ca' || field == 'zone') {
      expect(refusal, TrustRefusal.conflicts);
      expect(kept, isNull);
    } else {
      expect(refusal, isNull);
      expect(kept!.sameAuthority(pinned), isTrue);
      expect(kept.retirement, greaterThanOrEqualTo(pinned.retirement));
    }
  });
}

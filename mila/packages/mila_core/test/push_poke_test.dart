import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hegel/hegel.dart';
import 'package:mila_core/src/push_poke.dart';
import 'package:test/test.dart';

/// The shared vectors Marshall's sealer is tested against too.
final Map<String, Object?> _fixture =
    jsonDecode(File('../../../protocol/test/fixtures/push_pokes.json').readAsStringSync())
        as Map<String, Object?>;

List<Map<String, Object?>> _vectors(String key) =>
    (_fixture[key]! as List<Object?>).cast<Map<String, Object?>>();

Uint8List _hex(Object? value) {
  final text = value! as String;
  return Uint8List.fromList([
    for (var i = 0; i < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16),
  ]);
}

const String _host = 'control.example.test';
const String _machine = '2f0b8f8e-3c1d-4a8e-9b3e-0c6f1d2a7b11';
const String _thread = '7a1c0e44-91f2-4d1e-8a5b-3e2f6c9d0a12';

final PokeKeyPair _device = PokeKeyPair.fromPrivate(
  _hex(_vectors('valid').first['device_private']),
)!;

String _seal(String json, {String host = _host, Uint8List? devicePublic, int seed = 1}) => sealPoke(
  plaintext: Uint8List.fromList(utf8.encode(json)),
  host: host,
  devicePublic: devicePublic ?? _device.publicKey,
  ephemeralPrivate: Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + seed) & 0xff)),
  nonce: Uint8List.fromList(List<int>.generate(12, (i) => (i * 13 + seed) & 0xff)),
);

PokeRefusal? _refusal(PokeOpening opening) => switch (opening) {
  PokeRefused(:final reason) => reason,
  PokeOpened() => null,
};

/// Routes the poke producer may name: every page kind a notification opens.
final Generator<String> _route = sampledFrom([
  '/machines',
  '/threads',
  '/threads/$_thread',
  '/machines/$_machine',
  '/machines/$_machine/threads/$_thread',
  '/settings',
]);

void main() {
  test('the fixture describes format version 1', () {
    expect(_fixture['version'], pokeVersion);
    final format = _fixture['format']! as Map<String, Object?>;
    expect(format['key'], contains(pokeLabel));
    expect(format['plaintext'], contains('at most $maximumPokePlaintextBytes bytes'));
  });

  group('valid vectors', () {
    for (final vector in _vectors('valid')) {
      test(vector['name'], () {
        final keys = PokeKeyPair.fromPrivate(_hex(vector['device_private']))!;
        expect(keys.publicKey, _hex(vector['device_public']));
        final opening = openPoke(
          vector['poke']! as String,
          host: vector['host']! as String,
          keys: keys,
        );
        expect(opening, isA<PokeOpened>());
        final poke = (opening as PokeOpened).poke;
        final plain = jsonDecode(vector['plaintext']! as String) as Map<String, Object?>;
        expect(poke.kind.wire, plain['kind']);
        expect(poke.route.page.path, plain['route']);
        expect(poke.route.host, vector['host']);
        // Marshall's sealer is deterministic given the vector's randomness.
        final resealed = sealPoke(
          plaintext: Uint8List.fromList(utf8.encode(vector['plaintext']! as String)),
          host: vector['host']! as String,
          devicePublic: keys.publicKey,
          ephemeralPrivate: _hex(vector['ephemeral_private']),
          nonce: _hex(vector['nonce']),
        );
        expect(resealed, vector['poke']);
      });
    }
  });

  group('invalid vectors', () {
    for (final vector in _vectors('invalid')) {
      test(vector['name'], () {
        final keys = PokeKeyPair.fromPrivate(_hex(vector['device_private']))!;
        final opening = openPoke(
          vector['poke']! as String,
          host: vector['host']! as String,
          keys: keys,
        );
        expect(_refusal(opening)?.name, vector['reason']);
      });
    }
  });

  test('a poke for another device key is not authentic', () {
    final other = PokeKeyPair.fromPrivate(List<int>.filled(32, 9))!;
    final poke = _vectors('valid').first['poke']! as String;
    expect(_refusal(openPoke(poke, host: _host, keys: other)), PokeRefusal.authentication);
  });

  test('padding, foreign alphabets and non-canonical encodings are refused', () {
    final poke = _vectors('valid').first['poke']! as String;
    expect(_refusal(openPoke('$poke=', host: _host, keys: _device)), PokeRefusal.encoding);
    expect(
      _refusal(openPoke(poke.replaceAll('-', '+'), host: _host, keys: _device)),
      PokeRefusal.encoding,
    );
    expect(_refusal(openPoke('${poke}A', host: _host, keys: _device)), isNotNull);
    expect(decodeBase64UrlUnpadded('AB'), isNull, reason: 'trailing bits must be zero');
    expect(decodeBase64UrlUnpadded('AA'), [0]);
    expect(_refusal(openPoke('A' * 2000, host: _host, keys: _device)), PokeRefusal.length);
  });

  test('authentic plaintexts outside the v1 schema are refused', () {
    const route = '/threads/$_thread';
    for (final json in [
      '{"kind":"needs_input","route":"$route"}',
      '{"kind":"needs_input","route":"$route","v":2}',
      '{"kind":"needs_input","route":"$route","v":1.0}',
      '{"kind":"needs_input","route":"$route","v":"1"}',
      '{"kind":"agent_done","route":"$route","v":1}',
      '{"kind":"needs_input","route":"$route","v":1,"title":"hi"}',
      '{"kind":"needs_input","route":"/threads/NOT-A-UUID","v":1}',
      '{"kind":"needs_input","route":"/admin","v":1}',
      '{"kind":"needs_input","route":"https://evil.example/","v":1}',
      '{"kind":"needs_input","route":"//evil.example/machines","v":1}',
      '{"kind":"needs_input","route":"/machines/","v":1}',
      '{"kind":"needs_input","route":"$route#x","v":1}',
      '["needs_input"]',
      'not json',
      '',
    ]) {
      expect(
        _refusal(openPoke(_seal(json), host: _host, keys: _device)),
        PokeRefusal.plaintext,
        reason: json,
      );
    }
    // Over 512 plaintext bytes the sealed poke is longer than any v1 poke.
    final long = '{"kind":"needs_input","route":"$route","v":1,"p":"${'x' * 500}"}';
    expect(_refusal(openPoke(_seal(long), host: _host, keys: _device)), PokeRefusal.length);
    expect(decodePokePlaintext(utf8.encode(long), host: _host), isNull);
  });

  test('a low-order ephemeral key is refused before decryption', () {
    final poke = encodeBase64UrlUnpadded([
      1,
      ...List<int>.filled(32, 0),
      ...List<int>.filled(28, 0),
    ]);
    expect(_refusal(openPoke(poke, host: _host, keys: _device)), PokeRefusal.authentication);
  });

  property('sealed v1 pokes open to their own route for their own host only', (tc) {
    final route = tc.draw(_route, name: 'route');
    final seed = tc.draw(integers(min: 0, max: 255), name: 'seed');
    final json = jsonEncode({'kind': 'needs_input', 'route': route, 'v': 1});
    final poke = _seal(json, seed: seed);
    final opening = openPoke(poke, host: _host, keys: _device);
    expect(opening, isA<PokeOpened>());
    expect((opening as PokeOpened).poke.route.page.path, route);
    expect(opening.poke.route.host, _host);
    expect(
      _refusal(openPoke(poke, host: 'other.example.test', keys: _device)),
      PokeRefusal.authentication,
    );
  });

  property('changing any byte of a sealed poke is never accepted', (tc) {
    final route = tc.draw(_route, name: 'route');
    final poke = decodeBase64UrlUnpadded(
      _seal(jsonEncode({'kind': 'needs_input', 'route': route, 'v': 1})),
    )!;
    final index = tc.draw(integers(min: 0, max: poke.length - 1), name: 'index');
    final flip = tc.draw(integers(min: 1, max: 255), name: 'flip');
    final tampered = Uint8List.fromList(poke)..[index] ^= flip;
    final refusal = _refusal(
      openPoke(encodeBase64UrlUnpadded(tampered), host: _host, keys: _device),
    );
    expect(refusal, index == 0 ? PokeRefusal.version : PokeRefusal.authentication);
  });

  property('truncating or extending a sealed poke is never accepted', (tc) {
    final poke = decodeBase64UrlUnpadded(
      _seal(jsonEncode({'kind': 'needs_input', 'route': '/threads', 'v': 1})),
    )!;
    final cut = tc.draw(integers(min: 0, max: poke.length - 1), name: 'cut');
    final extra = tc.draw(bytes(minLength: 1, maxLength: 8), name: 'extra');
    for (final changed in [
      poke.sublist(0, cut),
      [...poke, ...extra],
    ]) {
      expect(
        _refusal(openPoke(encodeBase64UrlUnpadded(changed), host: _host, keys: _device)),
        isNotNull,
      );
    }
  });

  property('opening arbitrary text never throws or accepts', (tc) {
    final input = tc.draw(
      oneOf<String>([fromRegex(r'[A-Za-z0-9_-]{0,800}', fullMatch: true), text(maxLength: 200)]),
      name: 'text',
    );
    expect(openPoke(input, host: _host, keys: _device), isA<PokeRefused>());
  });

  property('generated device keys are distinct and round-trip through their text', (tc) {
    final seed = tc.draw(bytes(minLength: 32, maxLength: 32), name: 'private');
    final keys = PokeKeyPair.fromPrivate(seed)!;
    expect(decodeBase64UrlUnpadded(keys.publicKeyText), keys.publicKey);
    expect(keys.publicKeyText, hasLength(43));
  });
}

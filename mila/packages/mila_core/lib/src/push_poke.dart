/// End-to-end encrypted push pokes, format v1 (ADR-0224, ADR-0225).
///
/// Marshall seals `{v, kind, route}` to the device's X25519 key; the relay
/// sees only ciphertext. This is the reference opener the native extensions
/// mirror, tested against `protocol/test/fixtures/push_pokes.json`:
///
/// - layout: `0x01 || ephemeral_public(32) || nonce(12) || ciphertext || tag(16)`,
///   base64url without padding;
/// - key: `HKDF-SHA256(ikm = X25519(ephemeral, device), salt = ephemeral_public
///   || device_public, info = "overalls-mila-poke-v1", length = 32)`;
/// - AEAD: ChaCha20-Poly1305 (RFC 8439) with AAD
///   `"overalls-mila-poke-v1" || 0x00 || deployment host`;
/// - plaintext: a JSON object with exactly `v = 1`, a closed `kind` and a
///   canonical app route, at most 512 bytes.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pinenacl/tweetnacl.dart' show TweetNaCl;
import 'package:pointycastle/export.dart';

import 'app_route.dart';

/// The only poke format version.
const int pokeVersion = 1;

/// Domain separation for the key derivation and the AEAD.
const String pokeLabel = 'overalls-mila-poke-v1';

/// The most plaintext a poke may carry.
const int maximumPokePlaintextBytes = 512;

const int _publicBytes = 32;
const int _nonceBytes = 12;
const int _tagBytes = 16;
const int _headerBytes = 1 + _publicBytes + _nonceBytes;

/// The shortest sealed poke: header and tag around an empty ciphertext.
const int minimumPokeBytes = _headerBytes + _tagBytes;

/// The longest sealed poke.
const int maximumPokeBytes = minimumPokeBytes + maximumPokePlaintextBytes;

/// What a poke tells the device. The relay maps each kind to a fixed,
/// localized title; no text from the deployment is ever shown.
enum PokeKind {
  needsInput('needs_input');

  const PokeKind(this.wire);

  final String wire;

  static PokeKind? fromWire(String value) {
    for (final kind in values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// A decrypted, validated poke.
final class Poke {
  const Poke({required this.kind, required this.route});

  final PokeKind kind;

  /// Where tapping the notification leads, inside the decrypting deployment.
  final MilaRoute route;

  @override
  bool operator ==(Object other) => other is Poke && other.kind == kind && other.route == route;

  @override
  int get hashCode => Object.hash(kind, route);
}

/// Why a poke was refused. Never carries poke bytes.
enum PokeRefusal {
  /// Not unpadded base64url, or not canonical.
  encoding,

  /// Shorter than a header and tag, or longer than the largest poke.
  length,

  /// A version other than [pokeVersion].
  version,

  /// The AEAD rejected it: tampered, another device's key, or another
  /// deployment's associated data.
  authentication,

  /// Authentic, but the plaintext is not exactly a v1 poke.
  plaintext,
}

/// The outcome of opening a poke.
sealed class PokeOpening {
  const PokeOpening();
}

final class PokeOpened extends PokeOpening {
  const PokeOpened(this.poke);
  final Poke poke;
}

final class PokeRefused extends PokeOpening {
  const PokeRefused(this.reason);
  final PokeRefusal reason;
}

/// A device's X25519 key pair for pokes. The private half stays in platform
/// custody (Keychain, Keystore-wrapped storage or an owner-only file).
final class PokeKeyPair {
  PokeKeyPair._(this.privateKey, this.publicKey);

  /// A pair from a 32-byte private key; the scalar is clamped by X25519.
  static PokeKeyPair? fromPrivate(List<int> private) {
    if (private.length != _publicBytes) return null;
    final secret = Uint8List.fromList(private);
    final public = Uint8List(_publicBytes);
    TweetNaCl.crypto_scalarmult_base(public, secret);
    return PokeKeyPair._(secret, public);
  }

  /// A fresh pair from [random], which must be cryptographically secure.
  static PokeKeyPair generate(Random random) =>
      fromPrivate(List<int>.generate(_publicBytes, (_) => random.nextInt(256)))!;

  final Uint8List privateKey;
  final Uint8List publicKey;

  /// The public key as `device register --enc-pubkey` sends it.
  String get publicKeyText => encodeBase64UrlUnpadded(publicKey);
}

final RegExp _base64Url = RegExp(r'^[A-Za-z0-9_-]*$');

/// Unpadded base64url, as the poke and `--enc-pubkey` use.
String encodeBase64UrlUnpadded(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Strictly decodes unpadded base64url: no padding, no other alphabet, and
/// only the canonical encoding of its bytes. Returns null otherwise.
Uint8List? decodeBase64UrlUnpadded(String text) {
  if (!_base64Url.hasMatch(text) || text.length % 4 == 1) return null;
  final padded = text.padRight((text.length + 3) ~/ 4 * 4, '=');
  final Uint8List bytes;
  try {
    bytes = base64Url.decode(padded);
  } on FormatException {
    return null;
  }
  return encodeBase64UrlUnpadded(bytes) == text ? bytes : null;
}

/// The associated data binding a poke to one deployment host.
Uint8List pokeAssociatedData(String host) =>
    Uint8List.fromList([...ascii.encode(pokeLabel), 0, ...ascii.encode(host)]);

/// The per-poke AEAD key.
Uint8List derivePokeKey(Uint8List shared, Uint8List ephemeralPublic, Uint8List devicePublic) {
  final hkdf = HKDFKeyDerivator(SHA256Digest())
    ..init(
      HkdfParameters(
        shared,
        32,
        Uint8List.fromList([...ephemeralPublic, ...devicePublic]),
        Uint8List.fromList(ascii.encode(pokeLabel)),
      ),
    );
  final key = Uint8List(32);
  hkdf.deriveKey(null, 0, key, 0);
  return key;
}

/// X25519, or null for an all-zero (low-order) result.
Uint8List? x25519(Uint8List private, Uint8List public) {
  final out = Uint8List(_publicBytes);
  TweetNaCl.crypto_scalarmult(out, private, public);
  return out.every((b) => b == 0) ? null : out;
}

/// ChaCha20-Poly1305; [input] is ciphertext and tag when opening.
Uint8List? chacha20Poly1305(
  bool seal,
  Uint8List key,
  Uint8List nonce,
  Uint8List aad,
  Uint8List input,
) {
  final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305())
    ..init(seal, AEADParameters(KeyParameter(key), _tagBytes * 8, nonce, aad));
  final out = Uint8List(cipher.getOutputSize(input.length));
  try {
    final written = cipher.processBytes(input, 0, input.length, out, 0);
    final total = written + cipher.doFinal(out, written);
    return Uint8List.sublistView(out, 0, total);
  } on InvalidCipherTextException {
    return null;
  } on ArgumentError {
    return null;
  }
}

// @cc [owner:ghuntley,label:security;protocol] mila-poke-open-v1
// Opening a poke MUST refuse, without throwing, anything but an authentic v1
// poke sealed to this device's key for this deployment host, and MUST accept
// only exactly `{v: 1, kind, route}` with a closed kind and a canonical route
// of the same host. A refusal MUST NOT carry poke bytes or plaintext.
/// Opens [poke] for the deployment [host] with the device's [keys].
PokeOpening openPoke(String poke, {required String host, required PokeKeyPair keys}) {
  if (poke.length > (maximumPokeBytes * 4 + 2) ~/ 3) return const PokeRefused(PokeRefusal.length);
  final bytes = decodeBase64UrlUnpadded(poke);
  if (bytes == null) return const PokeRefused(PokeRefusal.encoding);
  if (bytes.length < minimumPokeBytes || bytes.length > maximumPokeBytes) {
    return const PokeRefused(PokeRefusal.length);
  }
  if (bytes[0] != pokeVersion) return const PokeRefused(PokeRefusal.version);
  if (!isHostname(host)) return const PokeRefused(PokeRefusal.authentication);
  final ephemeral = Uint8List.sublistView(bytes, 1, 1 + _publicBytes);
  final nonce = Uint8List.sublistView(bytes, 1 + _publicBytes, _headerBytes);
  final sealed = Uint8List.sublistView(bytes, _headerBytes);
  final shared = x25519(keys.privateKey, Uint8List.fromList(ephemeral));
  if (shared == null) return const PokeRefused(PokeRefusal.authentication);
  final key = derivePokeKey(shared, Uint8List.fromList(ephemeral), keys.publicKey);
  final plaintext = chacha20Poly1305(
    false,
    key,
    Uint8List.fromList(nonce),
    pokeAssociatedData(host),
    Uint8List.fromList(sealed),
  );
  if (plaintext == null) return const PokeRefused(PokeRefusal.authentication);
  final decoded = decodePokePlaintext(plaintext, host: host);
  return decoded == null ? const PokeRefused(PokeRefusal.plaintext) : PokeOpened(decoded);
}

/// Validates an authentic plaintext: exactly `v`, `kind` and `route`.
Poke? decodePokePlaintext(List<int> plaintext, {required String host}) {
  if (plaintext.length > maximumPokePlaintextBytes) return null;
  final Object? value;
  try {
    value = jsonDecode(utf8.decode(plaintext));
  } on FormatException {
    return null;
  }
  if (value is! Map<String, Object?> || value.length != 3) return null;
  final version = value['v'];
  final kindText = value['kind'];
  final path = value['route'];
  if (version is! int || version != pokeVersion || kindText is! String || path is! String) {
    return null;
  }
  final kind = PokeKind.fromWire(kindText);
  if (kind == null || !path.startsWith('/')) return null;
  final route = parseMilaRoute('overalls://$host$path');
  if (route == null || route.page.path != path) return null;
  return Poke(kind: kind, route: route);
}

/// Seals a poke as Marshall does. Mila never sends pokes; this exists so the
/// opener can be property-tested against arbitrary well-formed inputs.
String sealPoke({
  required Uint8List plaintext,
  required String host,
  required Uint8List devicePublic,
  required Uint8List ephemeralPrivate,
  required Uint8List nonce,
}) {
  final ephemeral = PokeKeyPair.fromPrivate(ephemeralPrivate)!;
  final shared = x25519(ephemeral.privateKey, devicePublic)!;
  final key = derivePokeKey(shared, ephemeral.publicKey, devicePublic);
  final sealed = chacha20Poly1305(true, key, nonce, pokeAssociatedData(host), plaintext)!;
  return encodeBase64UrlUnpadded([pokeVersion, ...ephemeral.publicKey, ...nonce, ...sealed]);
}

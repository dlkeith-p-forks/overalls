// The push relay client (ADR-0224). Mila asks Susan, the publisher-held
// relay at one fixed origin, for a push key binding this device's platform
// token to one deployment. Mila never sends Susan anything else: no account,
// no route, no deployment content.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mila_core/mila_core.dart';

// @cc [owner:ghuntley,label:security;privacy] mila-susan-fixed-origin
// Mila MUST reach the push relay only at the compiled origin, over HTTPS
// with the system trust store and no redirects. No setting, link or reply
// may change the origin, and the request MUST carry only the five fields of
// the key issuance contract.
/// The relay's only origin.
const String susanOrigin = 'https://notifications.overalls.dev';

/// The key issuance endpoint.
final Uri susanKeysUri = Uri.parse('$susanOrigin/api/push/v1/keys');

/// Mila's application identifier, as the stores know it.
const String milaAppId = 'dev.overalls.mila';

/// Push providers the relay accepts.
enum PushProvider {
  apns('apns'),
  fcm('fcm'),
  wns('wns');

  const PushProvider(this.wire);
  final String wire;

  /// Whether [token] has this provider's shape. Only WNS is checked: its
  /// token is a URI the relay will post to, so Mila refuses anything Susan's
  /// `susan-wns-channel-shape` rule would refuse rather than send it.
  bool accepts(String token) => this != wns || wnsChannel(token);
}

final RegExp _wnsHost = RegExp(
  r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\.notify\.windows\.com$',
);

/// A WNS channel URI: `https` on port 443 to a host under
/// `.notify.windows.com`, with a path, no userinfo or fragment, at most 1024
/// bytes (ADR-0236).
bool wnsChannel(String uri) {
  if (utf8.encode(uri).length > 1024 || uri.contains(RegExp(r'[\\ ]')) || uri.contains('%00')) {
    return false;
  }
  final parsed = Uri.tryParse(uri);
  return parsed != null &&
      parsed.scheme == 'https' &&
      parsed.userInfo.isEmpty &&
      !parsed.hasFragment &&
      parsed.port == 443 &&
      _wnsHost.hasMatch(parsed.host) &&
      uri.startsWith('https://${parsed.host}/');
}

/// APNs environments; FCM and WNS are always production.
enum PushEnvironment {
  production('production'),
  development('development');

  const PushEnvironment(this.wire);
  final String wire;

  static PushEnvironment? fromWire(String? value) => switch (value) {
    'production' => production,
    'development' => development,
    _ => null,
  };
}

/// One key issuance request.
final class PushKeyRequest {
  const PushKeyRequest({
    required this.provider,
    required this.token,
    required this.environment,
    required this.deployment,
  });

  final PushProvider provider;

  /// The platform push token. Never logged or stored by Mila.
  final String token;
  final PushEnvironment environment;

  /// The deployment's management host the key is bound to.
  final String deployment;

  /// The exact request body.
  List<int> encode() => utf8.encode(
    jsonEncode({
      'provider': provider.wire,
      'token': token,
      'app_id': milaAppId,
      'environment': environment.wire,
      'deployment': deployment,
    }),
  );

  @override
  String toString() => 'PushKeyRequest(${provider.wire}, ${environment.wire}, $deployment)';
}

/// An issued push key. [pushKey] is opaque to Mila and sent only to the
/// deployment, on `device register`'s stdin.
final class IssuedPushKey {
  const IssuedPushKey({required this.pushKey, required this.keyId, required this.expiresAt});
  final String pushKey;
  final String keyId;
  final DateTime expiresAt;

  @override
  String toString() => 'IssuedPushKey($keyId, $expiresAt)';
}

/// A relay reply after transport: status, `Retry-After` and body bytes.
final class SusanHttpResponse {
  const SusanHttpResponse(this.status, this.body, {this.retryAfter});
  final int status;
  final List<int> body;
  final Duration? retryAfter;
}

/// Sends one POST to the relay; throws on transport failure.
abstract interface class SusanTransport {
  Future<SusanHttpResponse> post(Uri uri, List<int> body);
}

/// The outcome of a key request.
sealed class PushKeyOutcome {
  const PushKeyOutcome();
}

final class PushKeyGranted extends PushKeyOutcome {
  const PushKeyGranted(this.key);
  final IssuedPushKey key;
}

final class PushKeyRefused extends PushKeyOutcome {
  const PushKeyRefused(this.failure, {this.retryAfter});
  final PushStepFailure failure;
  final Duration? retryAfter;
}

/// The longest push key Mila accepts; the relay's envelopes are far smaller.
const int maximumPushKeyLength = 2048;

/// The largest relay reply Mila reads.
const int maximumSusanReplyBytes = 4096;

final RegExp _pushKey = RegExp(r'^[A-Za-z0-9_-]+$');
final RegExp _keyId = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');
final RegExp _utc = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$');

/// Strictly decodes a 200/201 key reply: exactly the three fields, an
/// opaque base64url push key, a bounded key id and a UTC expiry after [now]
/// and no more than a year ahead.
IssuedPushKey? decodePushKeyReply(List<int> body, DateTime now) {
  if (body.length > maximumSusanReplyBytes) return null;
  final Object? value;
  try {
    value = jsonDecode(utf8.decode(body));
  } on FormatException {
    return null;
  }
  if (value is! Map<String, Object?> || value.length != 3) return null;
  final pushKey = value['push_key'];
  final keyId = value['key_id'];
  final expires = value['expires_at'];
  if (pushKey is! String ||
      pushKey.length > maximumPushKeyLength ||
      !_pushKey.hasMatch(pushKey) ||
      keyId is! String ||
      !_keyId.hasMatch(keyId) ||
      expires is! String ||
      !_utc.hasMatch(expires)) {
    return null;
  }
  final DateTime expiresAt;
  try {
    expiresAt = DateTime.parse(expires);
  } on FormatException {
    return null;
  }
  if (!expiresAt.isAfter(now) || expiresAt.isAfter(now.add(const Duration(days: 366)))) {
    return null;
  }
  return IssuedPushKey(pushKey: pushKey, keyId: keyId, expiresAt: expiresAt);
}

/// Maps a relay reply to an outcome: 2xx decodes strictly; 429 and 5xx may
/// clear; anything else is refused. 404 and 400 share one refusal, as the
/// relay makes them indistinguishable on purpose.
PushKeyOutcome classifyPushKeyReply(SusanHttpResponse response, DateTime now) {
  final status = response.status;
  if (status == 200 || status == 201) {
    final key = decodePushKeyReply(response.body, now);
    return key == null ? const PushKeyRefused(PushStepFailure.protocol) : PushKeyGranted(key);
  }
  if (status == 429 || (status >= 500 && status <= 599)) {
    return PushKeyRefused(PushStepFailure.transient, retryAfter: response.retryAfter);
  }
  return const PushKeyRefused(PushStepFailure.refused);
}

/// The relay client. Its origin is the compiled constant; only the transport
/// can be replaced, so a test can observe requests but never redirect them.
final class SusanClient {
  SusanClient({SusanTransport? transport, DateTime Function()? clock})
    : _transport = transport ?? HttpSusanTransport(),
      _clock = clock ?? DateTime.now;

  final SusanTransport _transport;
  final DateTime Function() _clock;

  /// Requests a push key; transport failures are transient.
  Future<PushKeyOutcome> issueKey(PushKeyRequest request) async {
    if (!isHostname(request.deployment) || request.token.isEmpty || request.token.length > 4096) {
      return const PushKeyRefused(PushStepFailure.refused);
    }
    final SusanHttpResponse response;
    try {
      response = await _transport.post(susanKeysUri, request.encode());
    } on Exception {
      return const PushKeyRefused(PushStepFailure.transient);
    }
    return classifyPushKeyReply(response, _clock().toUtc());
  }
}

/// `Retry-After` in seconds, bounded to a day; dates and junk are ignored.
Duration? parseRetryAfter(String? value) {
  if (value == null || !RegExp(r'^\d{1,6}$').hasMatch(value)) return null;
  final seconds = int.parse(value);
  return Duration(seconds: seconds > 86400 ? 86400 : seconds);
}

/// The production transport: `dart:io` with the system trust store, HTTPS
/// only, no redirects, no proxy, bounded size and time.
final class HttpSusanTransport implements SusanTransport {
  HttpSusanTransport({this.timeout = const Duration(seconds: 10)});

  final Duration timeout;

  @override
  Future<SusanHttpResponse> post(Uri uri, List<int> body) async {
    if (uri.scheme != 'https' || uri.origin != susanOrigin) {
      throw ArgumentError.value(uri.origin, 'uri', 'not the relay origin');
    }
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = ((_) => 'DIRECT');
    try {
      final request = await client.postUrl(uri)
        ..followRedirects = false
        ..headers.contentType = ContentType.json
        ..contentLength = body.length
        ..add(body);
      final response = await request.close().timeout(timeout);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        bytes.add(chunk);
        if (bytes.length > maximumSusanReplyBytes) {
          throw const HttpException('relay reply too large');
        }
      }
      return SusanHttpResponse(
        response.statusCode,
        bytes.takeBytes(),
        retryAfter: parseRetryAfter(response.headers.value(HttpHeaders.retryAfterHeader)),
      );
    } finally {
      client.close(force: true);
    }
  }
}

/// The platform token as an opaque digest, so the registration state can
/// notice rotation without holding the token.
String pushTokenDigest(String token) {
  // FNV-1a over UTF-8 is enough to notice change; it is never sent anywhere.
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(token)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return Uint8List.fromList(
    List<int>.generate(8, (i) => (hash >> (8 * i)) & 0xFF),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

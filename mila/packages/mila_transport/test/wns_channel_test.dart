import 'package:hegel/hegel.dart';
import 'package:mila_transport/mila_transport.dart';
import 'package:test/test.dart';

// Mirrors Susan's susan-wns-channel-shape rule (susan/lib/susan/provider.ex).
void main() {
  test('accepts the documented channel shape and refuses near misses', () {
    expect(wnsChannel('https://wns2-par02p.notify.windows.com/w/?token=AwYAAAB'), isTrue);
    expect(wnsChannel('https://bn3p.notify.windows.com/?token=x'), isTrue);
    for (final uri in [
      'http://wns2-par02p.notify.windows.com/w/?token=x',
      'https://notify.windows.com/w/?token=x',
      'https://evil.example/notify.windows.com/x',
      'https://wns.notify.windows.com.evil.example/w',
      'https://wns.notify.windows.com:8443/w',
      'https://user@wns.notify.windows.com/w',
      'https://wns.notify.windows.com/w#frag',
      'https://WNS.notify.windows.com/w',
      'https://wns.notify.windows.com',
      'https://wns.notify.windows.com/w\\..',
      'https://wns.notify.windows.com/${'a' * 1024}',
    ]) {
      expect(wnsChannel(uri), isFalse, reason: uri);
    }
    expect(PushProvider.apns.accepts('not-a-uri'), isTrue);
    expect(PushProvider.wns.accepts('not-a-uri'), isFalse);
  });

  property('an accepted channel always posts to a notify.windows.com host on 443', (tc) {
    final scheme = tc.draw(sampledFrom(['https', 'http', 'HTTPS', 'ftp']), name: 'scheme');
    final prefix = tc.draw(
      text(minLength: 1, maxLength: 20, minCodepoint: 0x2d, maxCodepoint: 0x7a),
      name: 'prefix',
    );
    final suffix = tc.draw(
      sampledFrom(['.notify.windows.com', '.windows.com', '.notify.windows.com.example', '']),
      name: 'suffix',
    );
    final port = tc.draw(sampledFrom(['', ':443', ':444', ':80']), name: 'port');
    final user = tc.draw(sampledFrom(['', 'u@', 'u:p@']), name: 'userinfo');
    final path = tc.draw(text(maxLength: 40), name: 'path');
    final uri = '$scheme://$user$prefix$suffix$port/$path';
    if (wnsChannel(uri)) {
      final parsed = Uri.parse(uri);
      expect(parsed.scheme, 'https');
      expect(parsed.port, 443);
      expect(parsed.userInfo, isEmpty);
      expect(parsed.host, endsWith('.notify.windows.com'));
    }
  });
}

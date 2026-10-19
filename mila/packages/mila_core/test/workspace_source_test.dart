import 'dart:convert';
import 'dart:io';

import 'package:hegel/hegel.dart';
import 'package:mila_core/src/workspace_source.dart';
import 'package:test/test.dart';

/// Shared with Lyra and `OverallsProtocol.WorkspaceSource`.
final File _vectors = File('../../../lyra/tests/fixtures/workspace_sources.json');

Map<String, Object?> _describe(WorkspaceSource source) => <String, Object?>{
  'version': 2,
  'provider': source.provider.name,
  'namespace': source.namespace,
  'repository': source.repository,
  'revision': switch (source.revision.kind) {
    RevisionKind.defaultBranch => <String, Object?>{'kind': 'default'},
    final kind => <String, Object?>{'kind': kind.name, 'value': source.revision.value},
  },
};

void main() {
  final document = jsonDecode(_vectors.readAsStringSync()) as Map<String, Object?>;

  test('shared vectors accept the same sources as the server', () {
    expect(document['version'], 2);
    final accepted = document['accepted']! as List<Object?>;
    expect(accepted, isNotEmpty);
    for (final entry in accepted.cast<Map<String, Object?>>()) {
      final url = entry['url']! as String;
      final result = parseWorkspaceSource(url);
      expect(result, isA<SourceAccepted>(), reason: url);
      final source = (result as SourceAccepted).source;
      expect(jsonEncode(_describe(source)), jsonEncode(entry['source']), reason: url);
      final again = parseWorkspaceSource(source.toUrl());
      expect(again, isA<SourceAccepted>(), reason: url);
      expect((again as SourceAccepted).source, source, reason: url);
    }
  });

  test('shared vectors refuse with the same reason as the server', () {
    final refused = document['refused']! as List<Object?>;
    expect(refused, isNotEmpty);
    for (final entry in refused.cast<Map<String, Object?>>()) {
      final url = entry['url']! as String;
      final result = parseWorkspaceSource(url);
      expect(result, isA<SourceRefused>(), reason: url);
      expect((result as SourceRefused).reason.wire, entry['reason'], reason: url);
    }
  });

  test('oversized URLs are refused before parsing', () {
    final url = 'https://github.com/o/r/tree/${'a' * 1024}';
    final result = parseWorkspaceSource(url);
    expect((result as SourceRefused).reason, SourceRefusal.invalidUrl);
  });

  final acceptedUrls = (document['accepted']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .map((entry) => entry['url']! as String)
      .toList();

  property('toUrl is idempotent through parsing', (tc) {
    final url = tc.draw(sampledFrom(acceptedUrls), name: 'url');
    final source = (parseWorkspaceSource(url) as SourceAccepted).source;
    final canonical = source.toUrl();
    final reparsed = (parseWorkspaceSource(canonical) as SourceAccepted).source;
    expect(reparsed.toUrl(), canonical);
  });

  property('parse is total', (tc) {
    final input = tc.draw(
      oneOf<String>([
        text(maxLength: 96),
        tuple2(sampledFrom(acceptedUrls), integers(min: 0, max: 200)).flatMap(
          (pair) => sampledFrom(const ['/', '.', '-', '%', '?', '#', ' ', '..', '@', '\u0000']).map(
            (insert) {
              final (url, position) = pair;
              final at = position.clamp(0, url.length);
              return url.substring(0, at) + insert + url.substring(at);
            },
          ),
        ),
      ]),
      name: 'input',
    );
    final result = parseWorkspaceSource(input);
    if (result is SourceAccepted) {
      final canonical = result.source.toUrl();
      expect((parseWorkspaceSource(canonical) as SourceAccepted).source, result.source);
    }
  });

  property('refs stay inside the closed alphabet', (tc) {
    final prefix = tc.draw(fromRegex(r'[a-z]{1,8}', fullMatch: true), name: 'prefix');
    final bad = tc.draw(
      sampledFrom(const [';', r'$', '`', '|', '&', ' ', '\\', '"', "'"]),
      name: 'bad',
    );
    final result = parseWorkspaceSource('https://github.com/o/r/tree/$prefix${bad}x');
    expect(result, isA<SourceRefused>());
  });
}

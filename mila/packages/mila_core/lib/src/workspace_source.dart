/// Public repository sources accepted by `new --source` and `/launch` links.
///
/// A line-for-line port of `OverallsProtocol.WorkspaceSource.parse_url/1`;
/// both sides are tested against `lyra/tests/fixtures/workspace_sources.json`.
library;

import 'dart:convert';

/// Repository hosts Overalls can open.
enum SourceProvider {
  github('github.com'),
  gitlab('gitlab.com'),
  codeberg('codeberg.org'),
  bitbucket('bitbucket.org');

  const SourceProvider(this.host);

  /// The provider's fixed HTTPS host.
  final String host;
}

/// What a parsed source revision names.
enum RevisionKind { defaultBranch, ref, tag, commit, change }

/// A revision of a repository: the default branch, a named ref or tag, a
/// commit, or a change (pull/merge request) number.
final class Revision {
  const Revision.defaultBranch() : kind = RevisionKind.defaultBranch, value = null;
  const Revision.named(this.kind, String this.value);
  const Revision.change(int this.value) : kind = RevisionKind.change;

  final RevisionKind kind;

  /// A `String` for ref, tag and commit; an `int` for change; null otherwise.
  final Object? value;

  @override
  bool operator ==(Object other) => other is Revision && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

/// Why a URL was refused, matching the Elixir reason atoms.
enum SourceRefusal {
  invalidUrl('invalid_url'),
  unsupportedHost('unsupported_host'),
  invalidNamespace('invalid_namespace'),
  invalidRepository('invalid_repository'),
  invalidReference('invalid_reference');

  const SourceRefusal(this.wire);

  /// The reason as the shared vectors spell it.
  final String wire;
}

/// A validated public repository source.
final class WorkspaceSource {
  const WorkspaceSource({
    required this.provider,
    required this.namespace,
    required this.repository,
    required this.revision,
  });

  final SourceProvider provider;
  final List<String> namespace;
  final String repository;
  final Revision revision;

  /// The canonical provider URL for this source.
  String toUrl() {
    final base = 'https://${provider.host}/${[...namespace, repository].join('/')}';
    final value = revision.value;
    return switch ((provider, revision.kind)) {
      (_, RevisionKind.defaultBranch) => base,
      (SourceProvider.github, RevisionKind.ref) => '$base/tree/$value',
      (SourceProvider.github, RevisionKind.tag) => '$base/releases/tag/$value',
      (SourceProvider.github, RevisionKind.commit) => '$base/commit/$value',
      (SourceProvider.github, RevisionKind.change) => '$base/pull/$value',
      (SourceProvider.gitlab, RevisionKind.ref) => '$base/-/tree/$value',
      (SourceProvider.gitlab, RevisionKind.tag) => '$base/-/tags/$value',
      (SourceProvider.gitlab, RevisionKind.commit) => '$base/-/commit/$value',
      (SourceProvider.gitlab, RevisionKind.change) => '$base/-/merge_requests/$value',
      (SourceProvider.codeberg, RevisionKind.ref) => '$base/src/branch/$value',
      (SourceProvider.codeberg, RevisionKind.tag) => '$base/src/tag/$value',
      (SourceProvider.codeberg, RevisionKind.commit) => '$base/commit/$value',
      (SourceProvider.codeberg, RevisionKind.change) => '$base/pulls/$value',
      (SourceProvider.bitbucket, RevisionKind.ref) => '$base/src/$value',
      (SourceProvider.bitbucket, RevisionKind.commit) => '$base/commits/$value',
      (SourceProvider.bitbucket, RevisionKind.change) => '$base/pull-requests/$value',
      // Bitbucket has no tag route; parsing never produces this combination.
      (SourceProvider.bitbucket, RevisionKind.tag) => '$base/src/$value',
    };
  }

  @override
  bool operator ==(Object other) =>
      other is WorkspaceSource &&
      other.provider == provider &&
      other.repository == repository &&
      other.revision == revision &&
      other.namespace.length == namespace.length &&
      Iterable<int>.generate(namespace.length).every((i) => other.namespace[i] == namespace[i]);

  @override
  int get hashCode => Object.hash(provider, Object.hashAll(namespace), repository, revision);
}

/// The outcome of [parseWorkspaceSource].
sealed class SourceResult {
  const SourceResult();
}

final class SourceAccepted extends SourceResult {
  const SourceAccepted(this.source);
  final WorkspaceSource source;
}

final class SourceRefused extends SourceResult {
  const SourceRefused(this.reason);
  final SourceRefusal reason;
}

final RegExp _githubOwner = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$');
final RegExp _component = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9._-]{0,99}$');
final RegExp _repository = RegExp(r'^[A-Za-z0-9._-]{1,100}$');
final RegExp _namedRef = RegExp(r'^[A-Za-z0-9._/@+=,-]{1,255}$');
final RegExp _commit = RegExp(r'^[0-9a-fA-F]{7,64}$');
final RegExp _change = RegExp(r'^[1-9][0-9]{0,9}$');

/// Parses a provider URL into a [WorkspaceSource] or a closed refusal.
SourceResult parseWorkspaceSource(String url) {
  if (utf8.encode(url).length > 1024) {
    return const SourceRefused(SourceRefusal.invalidUrl);
  }
  final stripped = url.split(RegExp(r'[?#]')).first;
  final (SourceProvider? provider, String? path) = _providerPath(stripped);
  if (provider == null || path == null) {
    final reason = stripped.startsWith('https://') || stripped.startsWith('http://')
        ? SourceRefusal.unsupportedHost
        : SourceRefusal.invalidUrl;
    return SourceRefused(reason);
  }
  var trimmed = path;
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final parts = trimmed.split('/');
  final split = _repositoryPath(provider, parts);
  if (split == null) return const SourceRefused(SourceRefusal.invalidUrl);
  final (namespace, rawRepository, rest) = split;
  if (!_namespaceValid(provider, namespace)) {
    return const SourceRefused(SourceRefusal.invalidNamespace);
  }
  final repository = rawRepository.endsWith('.git')
      ? rawRepository.substring(0, rawRepository.length - 4)
      : rawRepository;
  if (!_repositoryValid(repository)) {
    return const SourceRefused(SourceRefusal.invalidRepository);
  }
  final revision = _revision(provider, rest);
  if (revision == null) return const SourceRefused(SourceRefusal.invalidReference);
  return SourceAccepted(
    WorkspaceSource(
      provider: provider,
      namespace: List<String>.unmodifiable(namespace),
      repository: repository,
      revision: revision,
    ),
  );
}

(SourceProvider?, String?) _providerPath(String url) {
  for (final provider in SourceProvider.values) {
    final prefix = 'https://${provider.host}/';
    if (url.startsWith(prefix)) return (provider, url.substring(prefix.length));
  }
  return (null, null);
}

(List<String>, String, List<String>)? _repositoryPath(SourceProvider provider, List<String> parts) {
  if (provider == SourceProvider.gitlab) {
    final dash = parts.indexOf('-');
    final identity = dash < 0 ? parts : parts.sublist(0, dash);
    final rest = dash < 0 ? <String>[] : parts.sublist(dash);
    if (identity.length < 2) return null;
    return (identity.sublist(0, identity.length - 1), identity.last, rest);
  }
  if (parts.length < 2) return null;
  return (<String>[parts[0]], parts[1], parts.sublist(2));
}

bool _namespaceValid(SourceProvider provider, List<String> parts) {
  if (provider == SourceProvider.github) {
    return parts.length == 1 && _githubOwner.hasMatch(parts.single);
  }
  if (parts.isEmpty) return false;
  return (provider == SourceProvider.gitlab || parts.length == 1) &&
      parts.every((part) => _component.hasMatch(part) && !part.contains('..')) &&
      utf8.encode(parts.join('/')).length <= 255;
}

bool _repositoryValid(String value) =>
    _repository.hasMatch(value) &&
    value != '.' &&
    value != '..' &&
    !value.startsWith('-') &&
    !value.endsWith('.git');

Revision? _revision(SourceProvider provider, List<String> rest) {
  if (rest.isEmpty) return const Revision.defaultBranch();
  List<String> after(int n) => rest.sublist(n);
  bool starts(List<String> prefix) =>
      rest.length >= prefix.length &&
      Iterable<int>.generate(prefix.length).every((i) => rest[i] == prefix[i]);

  switch (provider) {
    case SourceProvider.github:
      if (starts(['tree'])) return _named(RevisionKind.ref, after(1));
      if (starts(['releases', 'tag'])) return _named(RevisionKind.tag, after(2));
      if (rest.length == 2 && rest[0] == 'commit') return _commitOf(rest[1]);
      if (rest.length >= 2 && rest[0] == 'pull') {
        return _changeOf(rest[1], after(2), const ['files', 'commits', 'checks']);
      }
    case SourceProvider.gitlab:
      if (starts(['-', 'tree'])) return _named(RevisionKind.ref, after(2));
      if (starts(['-', 'tags']) || starts(['-', 'releases'])) {
        return _named(RevisionKind.tag, after(2));
      }
      if (rest.length == 3 && starts(['-', 'commit'])) return _commitOf(rest[2]);
      if (rest.length >= 3 && starts(['-', 'merge_requests'])) {
        return _changeOf(rest[2], after(3), const ['diffs', 'commits', 'pipelines', 'changes']);
      }
    case SourceProvider.codeberg:
      if (starts(['src', 'branch'])) return _named(RevisionKind.ref, after(2));
      if (starts(['src', 'tag'])) return _named(RevisionKind.tag, after(2));
      if (starts(['releases', 'tag'])) return _named(RevisionKind.tag, after(2));
      if (rest.length >= 3 && starts(['src', 'commit'])) {
        final tail = after(3);
        return tail.isEmpty || _namedValid(tail.join('/')) ? _commitOf(rest[2]) : null;
      }
      if (rest.length == 2 && rest[0] == 'commit') return _commitOf(rest[1]);
      if (rest.length >= 2 && rest[0] == 'pulls') {
        return _changeOf(rest[1], after(2), const ['files', 'commits']);
      }
    case SourceProvider.bitbucket:
      if (starts(['src'])) return _named(RevisionKind.ref, after(1));
      if (rest.length == 2 && rest[0] == 'commits') return _commitOf(rest[1]);
      if (rest.length >= 2 && rest[0] == 'pull-requests') {
        return _changeOf(rest[1], after(2), const ['diff', 'commits', 'activity']);
      }
  }
  return null;
}

Revision? _named(RevisionKind kind, List<String> parts) {
  final value = parts.join('/');
  return _namedValid(value) ? Revision.named(kind, value) : null;
}

Revision? _commitOf(String value) =>
    _commit.hasMatch(value) ? Revision.named(RevisionKind.commit, value.toLowerCase()) : null;

Revision? _changeOf(String value, List<String> rest, List<String> tabs) {
  if (!_change.hasMatch(value)) return null;
  final number = int.parse(value);
  if (number > 2147483647) return null;
  if (rest.isNotEmpty && !(rest.length == 1 && tabs.contains(rest.single))) return null;
  return Revision.change(number);
}

bool _namedValid(String value) =>
    _namedRef.hasMatch(value) &&
    value != '@' &&
    !value.contains('..') &&
    !value.endsWith('.') &&
    value
        .split('/')
        .every(
          (part) =>
              part.isNotEmpty &&
              !part.startsWith('.') &&
              !part.startsWith('-') &&
              !part.endsWith('.lock'),
        );

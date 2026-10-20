/// The choices the new-machine form offers: the images `images --json`
/// lists and the teams `team list --json` lists. Rows that `new` would
/// refuse are dropped rather than offered.
library;

import 'app_route.dart' show isCanonicalUuid;
import 'ssh_command.dart';

/// One image a new machine may start from.
final class ImageChoice {
  const ImageChoice({required this.id, required this.name, this.architecture});

  /// The digest `new --image` takes.
  final String id;
  final String name;
  final String? architecture;
}

/// One team a new machine may belong to.
final class TeamChoice {
  const TeamChoice({required this.id, required this.name, required this.role});

  final String id;

  /// The name `new --team` takes.
  final String name;
  final String role;
}

bool _accepted(String option, String value) =>
    validateCommand(
      PorscheCommand('new', options: {'json': true, 'request-id': 'probe', option: value}),
    ) ==
    null;

/// Decodes an `images --json` result.
List<ImageChoice> decodeImageChoices(Map<String, Object?> result) {
  final items = result['images'];
  if (items is! List<Object?>) return const [];
  return List.unmodifiable([
    for (final item in items)
      if (item case {
        'id': final String id,
        'name': final String name,
      } when name.isNotEmpty && _accepted('image', id))
        ImageChoice(
          id: id,
          name: name,
          architecture: switch (item['architecture']) {
            final String a => a,
            _ => null,
          },
        ),
  ]);
}

/// Decodes one `team list --json` page and its cursor.
(List<TeamChoice>, String?) decodeTeamChoices(Map<String, Object?> result) {
  final items = result['items'];
  if (items is! List<Object?>) return (const [], null);
  final teams = [
    for (final item in items)
      if (item case {
        'id': final String id,
        'name': final String name,
        'role': final String role,
      } when isCanonicalUuid(id) && _accepted('team', name))
        TeamChoice(id: id, name: name, role: role),
  ];
  final next = result['next_cursor'];
  return (List.unmodifiable(teams), next is String && isCanonicalUuid(next) ? next : null);
}

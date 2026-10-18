import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/app_localizations.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'routes.dart';

final appearanceProvider = NotifierProvider<AppearanceNotifier, Appearance>(AppearanceNotifier.new);

final class AppearanceNotifier extends Notifier<Appearance> {
  @override
  Appearance build() => Appearance.system;

  void set(Appearance value) => state = value;
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final appearance = ref.watch(appearanceProvider);
    String name(Appearance a) => switch (a) {
      Appearance.system => l.appearanceSystem,
      Appearance.light => l.appearanceLight,
      Appearance.dark => l.appearanceDark,
    };
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          onPressed: () => context.go(deploymentsPath),
          child: BackGlyph(label: l.back),
        ),
        title: Text(l.settingsTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.all(MonoScale.fontSize),
        children: [
          Panel(
            title: l.appearance,
            child: Wrap(
              spacing: MonoScale.fontSize / 2,
              children: [
                for (final a in Appearance.values)
                  ConsoleButton(
                    key: Key('appearance-${a.name}'),
                    label: a == appearance ? '${Glyph.check.char} ${name(a)}' : name(a),
                    onPressed: () => ref.read(appearanceProvider.notifier).set(a),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

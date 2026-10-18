import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_transport/mila_transport.dart';

import '../l10n/app_localizations.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'routes.dart';
import 'session.dart';

class DeploymentsScreen extends ConsumerStatefulWidget {
  const DeploymentsScreen({super.key});

  @override
  ConsumerState<DeploymentsScreen> createState() => _DeploymentsScreenState();
}

class _DeploymentsScreenState extends ConsumerState<DeploymentsScreen> {
  final TextEditingController _host = TextEditingController();
  bool _invalid = false;

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  void _add() {
    final deployment = parseDeployment(_host.text);
    setState(() => _invalid = deployment == null);
    if (deployment == null) return;
    ref.read(deploymentsProvider.notifier).add(deployment);
    _host.clear();
    context.go(signInPath(deployment));
  }

  @override
  Widget build(BuildContext context) {
    final l = MilaLocalizations.of(context);
    final deployments = ref.watch(deploymentsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.deploymentsTitle),
        actions: [
          TextButton(
            key: const Key('open-settings'),
            onPressed: () => context.go(settingsPath),
            child: Text(l.settingsTitle.toUpperCase()),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(MonoScale.fontSize),
        children: [
          for (final deployment in deployments)
            Padding(
              padding: const EdgeInsets.only(bottom: MonoScale.line / 2),
              child: ConsoleButton(
                key: Key('deployment-$deployment'),
                label: deployment.toString(),
                glyph: Glyph.arrowRight,
                onPressed: () => context.go(signInPath(deployment)),
              ),
            ),
          const SizedBox(height: MonoScale.line),
          Panel(
            title: l.addDeployment,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const Key('deployment-host'),
                  controller: _host,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: l.deploymentHostLabel,
                    hintText: l.deploymentHostHint,
                    errorText: _invalid ? l.invalidHost : null,
                  ),
                  onSubmitted: (_) => _add(),
                ),
                const SizedBox(height: MonoScale.line / 2),
                ConsoleButton(
                  key: const Key('add-deployment'),
                  label: l.addDeployment,
                  glyph: Glyph.plus,
                  onPressed: _add,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

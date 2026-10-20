import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_transport/mila_transport.dart';

import '../l10n/app_localizations.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'routes.dart';
import 'session.dart';
import 'sign_in_screen.dart' show SignInAutoStart;

/// Navigation `extra` carrying a host to offer in the add field, as a link
/// to a deployment not yet added does.
final class DeploymentPrefill {
  const DeploymentPrefill(this.host);
  final String host;
}

class DeploymentsScreen extends ConsumerStatefulWidget {
  const DeploymentsScreen({super.key, this.prefill});

  /// A host to place in the add field; never added without the user.
  final String? prefill;

  @override
  ConsumerState<DeploymentsScreen> createState() => _DeploymentsScreenState();
}

class _DeploymentsScreenState extends ConsumerState<DeploymentsScreen> {
  late final TextEditingController _host = TextEditingController(text: widget.prefill);
  bool _invalid = false;

  @override
  void didUpdateWidget(DeploymentsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final prefill = widget.prefill;
    if (prefill != null && prefill != oldWidget.prefill) _host.text = prefill;
  }

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
    // Adding a deployment is the request to sign in to it: the sign-in screen
    // starts at once, so the approval link opens without a second tap.
    context.go(signInPath(deployment), extra: const SignInAutoStart());
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
                // A signed-in deployment opens its machines; any other opens
                // sign-in, where a dropped connection can be resumed.
                onPressed: () => context.go(
                  ref.read(sessionProvider(deployment)) == null
                      ? signInPath(deployment)
                      : machinesPath(deployment),
                ),
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../l10n/app_localizations.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'routes.dart';
import 'session.dart';

/// Opens an approval link outside Mila. Overridden per platform.
final openExternalProvider = Provider<Future<void> Function(Uri)>((ref) => (uri) async {});

class SignInScreen extends ConsumerWidget {
  const SignInScreen({super.key, required this.deployment});

  final Deployment deployment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final view = ref.watch(signInProvider(deployment));
    final controller = ref.read(signInProvider(deployment).notifier);
    ref.listen(signInProvider(deployment), (previous, next) {
      if (next.flow.phase == SignInPhase.signedIn && previous?.flow.phase != SignInPhase.signedIn) {
        context.go(machinesPath(deployment));
      }
    });
    final flow = view.flow;
    final body = switch (flow.phase) {
      SignInPhase.idle => [
        ConsoleButton(
          key: const Key('sign-in-start'),
          label: l.signInStart,
          glyph: Glyph.arrowUpRight,
          onPressed: controller.start,
        ),
      ],
      SignInPhase.connecting => [
        Text(l.signInConnecting(deployment.toString()), key: const Key('sign-in-connecting')),
      ],
      SignInPhase.awaitingApproval => [
        Text(l.signInApprove),
        const SizedBox(height: MonoScale.line),
        Kv(
          l.signInFingerprint,
          SelectableText(
            flow.fingerprint ?? '',
            key: const Key('sign-in-fingerprint'),
            textDirection: TextDirection.ltr,
          ),
        ),
        const SizedBox(height: MonoScale.line),
        ConsoleButton(
          key: const Key('sign-in-open'),
          label: l.signInOpenBrowser,
          glyph: Glyph.arrowUpRight,
          onPressed: flow.showsLink
              ? () => ref.read(openExternalProvider)(flow.approvalUrl!)
              : null,
        ),
      ],
      SignInPhase.signedIn => <Widget>[],
      SignInPhase.expired => [
        Text(l.signInExpired, key: const Key('sign-in-expired')),
        const SizedBox(height: MonoScale.line),
        ConsoleButton(label: l.retry, onPressed: controller.start),
      ],
      SignInPhase.failed => [
        Text(switch (flow.failure) {
          SignInFailure.hostUntrusted => l.signInFailedHost,
          SignInFailure.refused => l.signInFailedRefused,
          SignInFailure.protocol || null => l.signInFailedProtocol,
        }, key: const Key('sign-in-failed')),
        const SizedBox(height: MonoScale.line),
        ConsoleButton(label: l.retry, onPressed: controller.start),
      ],
    };
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          onPressed: () => context.go(deploymentsPath),
          child: BackGlyph(label: l.back),
        ),
        title: Text(l.signInTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.all(MonoScale.fontSize),
        children: [
          Text(deployment.toString(), textDirection: TextDirection.ltr),
          const SizedBox(height: MonoScale.line),
          ...body,
        ],
      ),
    );
  }
}

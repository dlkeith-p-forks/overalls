import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_core/mila_core.dart' show isCanonicalUuid;
import 'package:mila_transport/mila_transport.dart';

import 'features/deployments_screen.dart';
import 'features/machines/machine_screen.dart';
import 'features/lock/app_lock_controller.dart';
import 'features/lock/lock_screen.dart';
import 'features/machines/machines_screen.dart';
import 'features/notifications/notifications_screen.dart';
import 'features/routes.dart';
import 'features/session.dart';
import 'features/settings_screen.dart';
import 'features/sign_in_screen.dart';
import 'features/terminal/terminal_screen.dart';
import 'features/terminal/terminals_screen.dart';
import 'features/threads/thread_screen.dart';
import 'features/threads/threads_screen.dart';
import 'features/web/web_screen.dart';
import 'l10n/app_localizations.dart';
import 'localization/fallback_delegates.dart';
import 'ui/theme.dart';
import 'ui/tokens.dart';

GoRouter buildRouter() {
  Widget deployment(GoRouterState state, Widget Function(Deployment) build) {
    final d = deploymentFromSegment(state.pathParameters['deployment']);
    return d == null ? const DeploymentsScreen() : build(d);
  }

  // Machine pages take canonical ids only; anything else lands on the
  // machine list rather than a page for an identifier that cannot exist.
  Widget machine(
    GoRouterState state,
    Widget Function(Deployment, String, Map<String, String>) build, {
    List<String> ids = const [],
  }) => deployment(state, (d) {
    final id = state.pathParameters['id'];
    final values = {for (final name in ids) name: state.pathParameters[name] ?? ''};
    final valid = (id == null || isCanonicalUuid(id)) && values.values.every(isCanonicalUuid);
    return valid ? build(d, id ?? '', values) : MachinesScreen(deployment: d);
  });

  return GoRouter(
    routes: [
      GoRoute(path: deploymentsPath, builder: (context, state) => const DeploymentsScreen()),
      GoRoute(path: settingsPath, builder: (context, state) => const SettingsScreen()),
      GoRoute(
        path: '/d/:deployment/sign-in',
        builder: (context, state) => deployment(state, (d) => SignInScreen(deployment: d)),
      ),
      GoRoute(
        path: '/d/:deployment/machines',
        builder: (context, state) => deployment(state, (d) => MachinesScreen(deployment: d)),
      ),
      GoRoute(
        path: '/d/:deployment/notifications',
        builder: (context, state) => deployment(state, (d) => NotificationsScreen(deployment: d)),
      ),
      GoRoute(
        path: '/d/:deployment/threads',
        builder: (context, state) => deployment(state, (d) => RecentThreadsScreen(deployment: d)),
      ),
      GoRoute(
        path: '/d/:deployment/threads/:thread',
        builder: (context, state) => machine(
          state,
          (d, _, ids) => ThreadScreen(deployment: d, threadId: ids['thread']!),
          ids: const ['thread'],
        ),
      ),
      GoRoute(
        path: '/d/:deployment/machines/:id',
        builder: (context, state) =>
            machine(state, (d, id, _) => MachineScreen(deployment: d, machineId: id)),
      ),
      GoRoute(
        path: '/d/:deployment/machines/:id/info',
        builder: (context, state) =>
            machine(state, (d, id, _) => MachineScreen(deployment: d, machineId: id)),
      ),
      GoRoute(
        path: '/d/:deployment/machines/:id/terminals',
        builder: (context, state) =>
            machine(state, (d, id, _) => TerminalsScreen(deployment: d, machineId: id)),
      ),
      GoRoute(
        path: '/d/:deployment/machines/:id/terminals/:session',
        builder: (context, state) => machine(
          state,
          (d, id, ids) => TerminalScreen(deployment: d, machineId: id, sessionId: ids['session']!),
          ids: const ['session'],
        ),
      ),
      GoRoute(
        path: '/d/:deployment/machines/:id/threads',
        builder: (context, state) =>
            machine(state, (d, id, _) => MachineThreadsScreen(deployment: d, machineId: id)),
      ),
      GoRoute(
        path: '/d/:deployment/machines/:id/threads/:thread',
        builder: (context, state) => machine(
          state,
          (d, id, ids) => ThreadScreen(deployment: d, machineId: id, threadId: ids['thread']!),
          ids: const ['thread'],
        ),
      ),
      GoRoute(
        path: '/d/:deployment/machines/:id/web',
        builder: (context, state) =>
            machine(state, (d, id, _) => WebScreen(deployment: d, machineId: id)),
      ),
    ],
  );
}

final routerProvider = Provider<GoRouter>((ref) => buildRouter());

/// `overalls://` links the platform delivers: at launch and while running.
/// Platform deep linking is disabled so links reach only [followLink].
final incomingLinksProvider = Provider<Stream<String>>((ref) => const Stream.empty());

class MilaApp extends ConsumerStatefulWidget {
  const MilaApp({super.key});

  @override
  ConsumerState<MilaApp> createState() => _MilaAppState();
}

class _MilaAppState extends ConsumerState<MilaApp> {
  StreamSubscription<String>? _links;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _links = ref.read(incomingLinksProvider).listen((link) => followLink(ref, link));
    // Hidden covers both the app switcher and the background; the lock
    // policy decides what each means.
    _lifecycle = AppLifecycleListener(
      onHide: () => ref.read(appLockProvider.notifier).backgrounded(),
      onShow: () => ref.read(appLockProvider.notifier).foregrounded(),
    );
  }

  @override
  void dispose() {
    unawaited(_links?.cancel());
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appearance = ref.watch(appearanceProvider);
    final platform = MediaQuery.platformBrightnessOf(context);
    final brightness = switch (appearance) {
      Appearance.system => platform,
      Appearance.light => Brightness.light,
      Appearance.dark => Brightness.dark,
    };
    final tokens = brightness == Brightness.dark ? MonoTokens.dark : MonoTokens.light;
    return MonoTheme(
      tokens: tokens,
      child: MaterialApp.router(
        onGenerateTitle: (context) => MilaLocalizations.of(context).appTitle,
        theme: monoThemeData(tokens, brightness),
        routerConfig: ref.watch(routerProvider),
        localizationsDelegates: const [MilaLocalizations.delegate, ...frameworkDelegates],
        supportedLocales: MilaLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        builder: (context, child) => LockGate(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}

/// Follows an `overalls://` link, never acting beyond navigation.
void followLink(WidgetRef ref, String link) {
  final deployments = ref.read(deploymentsProvider);
  final target = linkTarget(
    link,
    deployments,
    signedIn: (d) => ref.read(sessionProvider(d)) != null,
  );
  final router = ref.read(routerProvider);
  switch (target) {
    case OpenPath(:final path):
      router.go(path);
    case UnknownDeployment() || RefusedLink():
      router.go(deploymentsPath);
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_transport/mila_transport.dart';

import 'features/deployments_screen.dart';
import 'features/machines/machine_screen.dart';
import 'features/machines/machines_screen.dart';
import 'features/routes.dart';
import 'features/session.dart';
import 'features/settings_screen.dart';
import 'features/sign_in_screen.dart';
import 'l10n/app_localizations.dart';
import 'ui/theme.dart';
import 'ui/tokens.dart';

GoRouter buildRouter() {
  Widget deployment(GoRouterState state, Widget Function(Deployment) build) {
    final d = deploymentFromSegment(state.pathParameters['deployment']);
    return d == null ? const DeploymentsScreen() : build(d);
  }

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
        path: '/d/:deployment/machines/:id',
        builder: (context, state) => deployment(
          state,
          (d) => MachineScreen(deployment: d, machineId: state.pathParameters['id']!),
        ),
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

  @override
  void initState() {
    super.initState();
    _links = ref.read(incomingLinksProvider).listen((link) => followLink(ref, link));
  }

  @override
  void dispose() {
    unawaited(_links?.cancel());
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
        localizationsDelegates: const [
          MilaLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: MilaLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
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

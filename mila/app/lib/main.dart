import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'features/session.dart';
import 'features/sign_in_screen.dart';
import 'transport/fake_porsche.dart';
import 'transport/platform.dart';

/// `--dart-define=MILA_DEMO=true` runs against an in-memory deployment so the
/// Linux build can be exercised without a control plane.
const bool _demo = bool.fromEnvironment('MILA_DEMO');

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!_demo) {
    final connector = await platformConnector();
    runApp(
      ProviderScope(
        overrides: [
          connectorProvider.overrideWithValue(connector),
          openExternalProvider.overrideWithValue(openApprovalLink),
          incomingLinksProvider.overrideWithValue(platformLinks(arguments)),
        ],
        child: const MilaApp(),
      ),
    );
    return;
  }
  final demo = FakeDeployment(
    'demo.overalls.example',
    approved: true,
    machines: [
      FakeMachine('0d9cc041-9db2-4e4c-b28b-1e41d7f472c1', 'dev-box'),
      FakeMachine(
        '6f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b',
        'scratch',
        desired: 'stopped',
        observed: 'stopped',
      ),
    ],
  );
  runApp(
    ProviderScope(
      overrides: [
        connectorProvider.overrideWithValue(FakePorscheConnector({demo.host: demo})),
      ],
      child: const MilaApp(),
    ),
  );
}

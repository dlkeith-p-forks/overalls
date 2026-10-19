// Terminal, thread and web flows against the fake Porsche (ADR-0222,
// ADR-0223). Every assertion is on the encoded command lines and JSON the
// real gateway would see.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mila/app.dart';
import 'package:mila/features/routes.dart';
import 'package:mila/features/session.dart';
import 'package:mila/features/sign_in_screen.dart';
import 'package:mila/features/terminal/terminal_controller.dart';
import 'package:mila/transport/fake_porsche.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

const String _host = 'overalls.example';
const Deployment _deployment = Deployment(_host);
const String _box = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
const String _term = '019a0f73-1111-4222-8333-444455556666';
const String _thread = '019a0f71-aaaa-4bbb-8ccc-ddddeeeeffff';
const String _plan = '019a0f75-1234-4567-89ab-cdef01234567';
const String _question = '019a0f76-1234-4567-89ab-cdef01234567';

final class _App {
  _App(this.fake, this.router, this.opened, this.links);
  final FakeDeployment fake;
  final GoRouter router;
  final List<Uri> opened;
  final StreamController<String> links;

  String get location => router.routerDelegate.currentConfiguration.uri.toString();

  /// Lines sent after [mark].
  Iterable<String> since(int mark) => fake.received.skip(mark);
}

Future<_App> _signedIn(WidgetTester tester, {String? clipboard}) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = FakeDeployment(_host, approved: true, machines: [FakeMachine(_box, 'dev-box')]);
  final opened = <Uri>[];
  final links = StreamController<String>();
  addTearDown(links.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectorProvider.overrideWithValue(FakePorscheConnector({_host: fake})),
        openExternalProvider.overrideWithValue((uri) async => opened.add(uri)),
        incomingLinksProvider.overrideWithValue(links.stream),
        clipboardReaderProvider.overrideWithValue(() async => clipboard),
      ],
      child: const MilaApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('deployment-host')), _host);
  await tester.tap(find.byKey(const Key('add-deployment')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('sign-in-start')));
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  return _App(fake, container.read(routerProvider), opened, links);
}

Future<void> _go(WidgetTester tester, _App app, String path) async {
  app.router.go(path);
  await tester.pumpAndSettle();
}

/// Leaves the page so autoDispose controllers close their channels and
/// timers before the test ends.
Future<void> _leave(WidgetTester tester, _App app) => _go(tester, app, machinesPath(_deployment));

FakeThread _seedThread(FakeDeployment fake) {
  final thread = FakeThread(_thread, 'Fix the build', machineId: _box)
    ..add('prompt', {'prompt': 'Why does CI fail?'})
    ..add('assistant', {'text': 'A missing import.'});
  fake.threads[_thread] = thread;
  return thread;
}

/// The received lines that parse as [name] with exactly [arguments], whatever
/// the option order the encoder chose.
Iterable<String> _invocations(List<String> lines, String name, List<String> arguments) =>
    lines.where((line) {
      final parsed = parseCommandLine(line);
      return parsed != null &&
          parsed.name == name &&
          parsed.arguments.length == arguments.length &&
          Iterable<int>.generate(arguments.length)
              .every((i) => parsed.arguments[i] == arguments[i]);
    });

void main() {
  group('terminal', () {
    testWidgets('attaches, types through the extra keys and resumes from its cursor', (
      tester,
    ) async {
      final app = await _signedIn(tester);
      app.fake.terminals[_term] = FakeTerminal(_term, _box)..output.addAll(utf8.encode('hi\r\n'));
      await _go(tester, app, machineTerminalsPath(_deployment, _box));
      expect(find.byKey(const Key('terminal-$_term')), findsOneWidget);

      await tester.tap(find.byKey(const Key('terminal-open-$_term')));
      await tester.pumpAndSettle();
      expect(app.location, machineTerminalPath(_deployment, _box, _term));
      final first = app.fake.attaches.single;
      expect(first.line, startsWith('terminal attach $_box $_term'));
      expect(first.line, isNot(contains('--cursor')));
      expect(find.text('[live]'), findsOneWidget);

      await tester.tap(find.byKey(const Key('extra-esc')));
      await tester.pump();
      expect(first.inputLengths, [1]);

      // A dropped channel reattaches from the bytes already shown.
      await first.end(5);
      await tester.pump();
      expect(find.text('[reconnecting]'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      final second = app.fake.attaches.last;
      expect(second, isNot(same(first)));
      expect(second.line, contains('--cursor=${first.terminal.output.length}'));
      await _leave(tester, app);
    });

    testWidgets('view-only mode never sends keys or pastes', (tester) async {
      final app = await _signedIn(tester, clipboard: 'rm -rf /');
      app.fake.terminals[_term] = FakeTerminal(_term, _box);
      await _go(tester, app, machineTerminalPath(_deployment, _box, _term));
      await tester.tap(find.byKey(const Key('terminal-mode-1')));
      await tester.pumpAndSettle();
      expect(find.text('[view only]'), findsOneWidget);
      await tester.tap(find.byKey(const Key('extra-paste')), warnIfMissed: false);
      await tester.tap(find.byKey(const Key('extra-tab')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(app.fake.attaches.expand((a) => a.inputLengths), isEmpty);
      await _leave(tester, app);
    });

    testWidgets('an authority refusal stops reconnecting', (tester) async {
      final app = await _signedIn(tester);
      app.fake.terminals[_term] = FakeTerminal(_term, _box);
      await _go(tester, app, machineTerminalPath(_deployment, _box, _term));
      await app.fake.attaches.single.end(3);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 1));
      expect(app.fake.attaches, hasLength(1));
      expect(find.byKey(const Key('terminal-retry')), findsOneWidget);
      await _leave(tester, app);
    });

    testWidgets('a new session is opened once with a request id', (tester) async {
      final app = await _signedIn(tester);
      await _go(tester, app, machineTerminalsPath(_deployment, _box));
      await tester.tap(find.byKey(const Key('terminal-new')));
      await tester.pumpAndSettle();
      final news = app.fake.received.where((l) => l.startsWith('terminal new '));
      expect(news, hasLength(1));
      expect(news.single, matches(RegExp(r'--request-id=porsche-[0-9a-f]{32}')));
      expect(app.fake.terminals, hasLength(1));
      await _leave(tester, app);
    });
  });

  group('threads', () {
    testWidgets('opening a thread shows its transcript and marks it read', (tester) async {
      final app = await _signedIn(tester);
      final thread = _seedThread(app.fake);
      await _go(tester, app, machineThreadsPath(_deployment, _box));
      expect(find.textContaining('2 new'), findsOneWidget);

      await tester.tap(find.byKey(const Key('thread-$_thread')));
      await tester.pumpAndSettle();
      expect(find.text('Why does CI fail?'), findsOneWidget);
      expect(find.text('A missing import.'), findsOneWidget);
      expect(_invocations(app.fake.received, 'thread read', [_thread, '2']), hasLength(1));
      expect(thread.readSequence, 2);
      await _leave(tester, app);
    });

    testWidgets('a prompt travels on stdin, never on the command line', (tester) async {
      final app = await _signedIn(tester);
      _seedThread(app.fake);
      await _go(tester, app, threadPath(_deployment, _thread));
      const secret = 'deploy with token hunter2';
      await tester.enterText(find.byKey(const Key('thread-composer')), secret);
      await tester.tap(find.byKey(const Key('thread-send')));
      await tester.pumpAndSettle();
      expect(app.fake.payloads, [secret]);
      expect(app.fake.received.any((l) => l.contains('hunter2')), isFalse);
      expect(_invocations(app.fake.received, 'thread prompt', [_thread, '-']), hasLength(1));
      await _leave(tester, app);
    });

    testWidgets('a plan is approved by its id and a question answered as JSON', (tester) async {
      final app = await _signedIn(tester);
      final thread = _seedThread(app.fake)
        ..plan = {'id': _plan, 'text': '1. Add the import.', 'implemented': false}
        ..question = {
          'id': _question,
          'questions': [
            {
              'id': 'q1',
              'header': 'Scope',
              'question': 'Fix tests too?',
              'options': [
                {'label': 'Yes', 'description': ''},
                {'label': 'No', 'description': ''},
              ],
            },
          ],
        };
      await _go(tester, app, threadPath(_deployment, _thread));
      expect(find.byKey(const Key('thread-plan')), findsOneWidget);
      await tester.tap(find.byKey(const Key('answer-q1-0')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('answer-send')));
      await tester.tap(find.byKey(const Key('answer-send')));
      await tester.pumpAndSettle();
      expect(
        _invocations(app.fake.received, 'thread answer', [_thread, _question, '-']),
        hasLength(1),
      );
      expect(jsonDecode(app.fake.payloads.single), {
        'q1': {'selected': 'Yes', 'text': ''},
      });

      await tester.ensureVisible(find.byKey(const Key('plan-approve')));
      await tester.tap(find.byKey(const Key('plan-approve')));
      await tester.pumpAndSettle();
      expect(
        _invocations(app.fake.received, 'thread plan approve', [_thread, _plan]),
        hasLength(1),
      );
      expect(thread.mode, 'work');
      await _leave(tester, app);
    });

    testWidgets('the recent grid totals unread updates and searches titles', (tester) async {
      final app = await _signedIn(tester);
      _seedThread(app.fake);
      app.fake.threads['019a0f71-0000-4000-8000-00000000000b'] = FakeThread(
        '019a0f71-0000-4000-8000-00000000000b',
        'Write docs',
      )..add('prompt', {'prompt': 'Draft a README'});
      await _go(tester, app, threadsPath(_deployment));
      expect(find.byKey(const Key('recent-unread')), findsOneWidget);
      expect(find.textContaining('3 unread updates'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('recent-search')), 'docs');
      await tester.pumpAndSettle();
      expect(find.text('Write docs'), findsOneWidget);
      expect(find.text('Fix the build'), findsNothing);
      await _leave(tester, app);
    });
  });

  group('web', () {
    testWidgets('a private address opens in the browser and visibility changes at its revision', (
      tester,
    ) async {
      final app = await _signedIn(tester);
      app.fake.webs[_box] = FakeWeb(_box, url: 'https://web-box-k3x9.apps.overalls.example/');
      await _go(tester, app, machineWebPath(_deployment, _box));
      expect(find.text('https://web-box-k3x9.apps.overalls.example/'), findsOneWidget);
      await tester.tap(find.byKey(const Key('web-open')));
      await tester.pumpAndSettle();
      expect(app.opened, [Uri.parse('https://web-box-k3x9.apps.overalls.example/')]);

      await tester.tap(find.byKey(const Key('web-visibility-0')));
      await tester.pumpAndSettle();
      final sets = _invocations(app.fake.received, 'web set', [_box]);
      expect(sets, hasLength(1));
      expect(sets.single, contains('--public'));
      expect(sets.single, contains('--revision=1'));
      expect(app.fake.webs[_box]!.visibility, 'public');
      await _leave(tester, app);
    });

    testWidgets('a concurrent change is reported, not overwritten', (tester) async {
      final app = await _signedIn(tester);
      final web = FakeWeb(_box);
      app.fake.webs[_box] = web;
      await _go(tester, app, machineWebPath(_deployment, _box));
      web.revision = 7;
      await tester.enterText(find.byKey(const Key('web-port')), '3000');
      await tester.tap(find.byKey(const Key('web-port-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('web-change-failed')), findsOneWidget);
      expect(web.port, 8080);
      await _leave(tester, app);
    });

    testWidgets('an out-of-range port is refused before sending', (tester) async {
      final app = await _signedIn(tester);
      app.fake.webs[_box] = FakeWeb(_box);
      await _go(tester, app, machineWebPath(_deployment, _box));
      final mark = app.fake.received.length;
      await tester.enterText(find.byKey(const Key('web-port')), '70000');
      await tester.tap(find.byKey(const Key('web-port-save')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a port from 1 to 65535.'), findsOneWidget);
      expect(app.since(mark).where((l) => l.startsWith('web set')), isEmpty);
      await _leave(tester, app);
    });
  });

  group('deep links', () {
    testWidgets('terminal and thread links only navigate', (tester) async {
      final app = await _signedIn(tester);
      app.fake.terminals[_term] = FakeTerminal(_term, _box);
      _seedThread(app.fake);
      final mark = app.fake.received.length;

      app.links.add('overalls://$_host/machines/$_box/terminals/$_term');
      await tester.pumpAndSettle();
      expect(app.location, machineTerminalPath(_deployment, _box, _term));

      app.links.add('overalls://$_host/threads/$_thread');
      await tester.pumpAndSettle();
      expect(app.location, threadPath(_deployment, _thread));

      app.links.add('overalls://$_host/machines/$_box/web');
      await tester.pumpAndSettle();
      expect(app.location, machineWebPath(_deployment, _box));

      // Opening pages reads and attaches; a link never mutates anything
      // beyond the thread read marker the opened page itself moves.
      const mutating = [
        'thread prompt',
        'thread answer',
        'thread plan',
        'thread mode',
        'terminal new',
        'terminal kill',
        'web set',
      ];
      expect(app.since(mark).where((l) => mutating.any(l.startsWith)), isEmpty);
      await _leave(tester, app);
    });
  });
}

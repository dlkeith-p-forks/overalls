// A machine's terminal sessions: `terminal ls`, `terminal new` and
// `terminal kill` (ADR-0223). Opening and closing are mutations submitted
// once and observed through `request show`.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../mutation.dart';
import '../session.dart';

/// Everything the terminal picker shows.
final class TerminalsView {
  const TerminalsView({
    this.sessions = const [],
    this.loading = false,
    this.failed = false,
    this.request,
  });

  final List<TerminalSession> sessions;
  final bool loading;
  final bool failed;

  /// The last open or close request, while it runs and after.
  final RequestPoll? request;

  TerminalsView copyWith({
    List<TerminalSession>? sessions,
    bool? loading,
    bool? failed,
    RequestPoll? request,
  }) => TerminalsView(
    sessions: sessions ?? this.sessions,
    loading: loading ?? this.loading,
    failed: failed ?? this.failed,
    request: request ?? this.request,
  );
}

/// A machine on a deployment.
typedef MachineKey = (Deployment, String);

final terminalsProvider = NotifierProvider.autoDispose
    .family<TerminalsController, TerminalsView, MachineKey>(TerminalsController.new);

final class TerminalsController extends Notifier<TerminalsView> {
  TerminalsController(this.key);

  final MachineKey key;
  WatchFeed? _feed;

  Deployment get _deployment => key.$1;
  String get _machine => key.$2;

  @override
  TerminalsView build() {
    final session = ref.watch(sessionProvider(_deployment));
    ref.onDispose(() => unawaited(_feed?.close()));
    if (session != null) {
      Future.microtask(refresh);
      final feed = WatchFeed(
        open: session.watch,
        filter: WatchFilter(machines: [_machine]),
        random: ref.read(randomProvider),
      );
      feed.events.listen((event) {
        if (event is TerminalSessionsChanged || event is Resync || event is Watching) {
          unawaited(refresh());
        }
      });
      feed.start();
      _feed = feed;
    }
    return const TerminalsView();
  }

  PorscheSession? get _session => ref.read(sessionProvider(_deployment));

  Future<void> refresh() async {
    final session = _session;
    if (session == null) return;
    state = state.copyWith(loading: true);
    final result = await readResult(
      session,
      PorscheCommand('terminal ls', arguments: [_machine], options: const {'json': true}),
    );
    if (!ref.mounted) return;
    if (result != null) {
      try {
        final (listing, _) = decodeTerminalList(result);
        state = state.copyWith(sessions: listing.items, loading: false, failed: false);
        return;
      } on TerminalFormatException {
        // Falls through to failed.
      }
    }
    state = state.copyWith(loading: false, failed: true);
  }

  /// Opens the user's personal session; returns its id once it exists.
  Future<String?> open() async {
    final session = _session;
    if (session == null) return null;
    final poll = await submitOnce(
      session,
      withRequestId(
        PorscheCommand('terminal new', arguments: [_machine]),
        ref.read(randomProvider),
      ),
      random: ref.read(randomProvider),
      onUpdate: (poll) {
        if (ref.mounted) state = state.copyWith(request: poll);
      },
    );
    if (!ref.mounted) return null;
    unawaited(refresh());
    if (poll.phase != PollPhase.succeeded) return null;
    try {
      return decodeTerminalNew(poll.result).sessionId;
    } on TerminalFormatException {
      return null;
    }
  }

  /// Closes [sessionId] for everyone viewing it.
  Future<void> kill(String sessionId) async {
    final session = _session;
    if (session == null) return;
    await submitOnce(
      session,
      withRequestId(
        PorscheCommand('terminal kill', arguments: [_machine, sessionId]),
        ref.read(randomProvider),
      ),
      random: ref.read(randomProvider),
      onUpdate: (poll) {
        if (ref.mounted) state = state.copyWith(request: poll);
      },
    );
    if (ref.mounted) await refresh();
  }
}

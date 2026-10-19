// A machine's published web endpoint: `web show` and `web set` with the
// endpoint's `policy_revision`, so a concurrent change is refused rather
// than overwritten (ADR-0222).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';

import '../mutation.dart';
import '../session.dart';
import '../terminal/terminals_controller.dart' show MachineKey;

/// Whether this platform shows public endpoints in an in-app webview
/// (iOS and Android); overridden at startup.
final inAppWebViewProvider = Provider<bool>((ref) => false);

/// Shares a link through the platform share sheet; null where there is
/// none (Linux), which offers copying only.
final shareLinkProvider = Provider<Future<void> Function(Uri)?>((ref) => null);

/// Why the last change did not apply.
enum WebChangeFailure { conflict, refused, failed }

final class WebEndpointView {
  const WebEndpointView({
    this.endpoint,
    this.loading = false,
    this.failed = false,
    this.saving = false,
    this.failure,
  });

  final WebEndpoint? endpoint;
  final bool loading;
  final bool failed;
  final bool saving;
  final WebChangeFailure? failure;
}

final webProvider = NotifierProvider.autoDispose.family<WebController, WebEndpointView, MachineKey>(
  WebController.new,
);

final class WebController extends Notifier<WebEndpointView> {
  WebController(this.key);

  final MachineKey key;

  @override
  WebEndpointView build() {
    if (ref.watch(sessionProvider(key.$1)) != null) Future.microtask(refresh);
    return const WebEndpointView(loading: true);
  }

  Future<void> refresh() async {
    final session = ref.read(sessionProvider(key.$1));
    if (session == null) return;
    final result = await readResult(
      session,
      PorscheCommand('web show', arguments: [key.$2], options: const {'json': true}),
    );
    if (!ref.mounted) return;
    try {
      final endpoint = result == null ? null : decodeWebEndpoint(result);
      state = WebEndpointView(endpoint: endpoint, failed: endpoint == null, failure: state.failure);
    } on WebFormatException {
      state = WebEndpointView(endpoint: state.endpoint, failed: true);
    }
  }

  /// Changes the port and/or visibility at the shown revision.
  Future<void> change({int? port, WebVisibility? visibility}) async {
    final session = ref.read(sessionProvider(key.$1));
    final current = state.endpoint;
    if (session == null || current == null) return;
    final random = ref.read(randomProvider);
    final command = webChange(
      current,
      port: port,
      visibility: visibility,
      requestId: allocateRequestId(random),
    );
    if (command == null) return;
    state = WebEndpointView(endpoint: current, saving: true);
    final poll = await submitOnce(session, command, random: random);
    if (!ref.mounted) return;
    if (poll.phase == PollPhase.succeeded) {
      try {
        state = WebEndpointView(endpoint: decodeWebEndpoint(poll.result));
        return;
      } on WebFormatException {
        // Re-read below.
      }
    }
    final failure = switch (poll) {
      RequestPoll(phase: PollPhase.succeeded) => null,
      RequestPoll(phase: PollPhase.refused, error: 'conflict' || 'stale_revision') =>
        WebChangeFailure.conflict,
      RequestPoll(phase: PollPhase.refused) => WebChangeFailure.refused,
      _ => WebChangeFailure.failed,
    };
    state = WebEndpointView(endpoint: current, failure: failure);
    unawaited(refresh());
  }
}

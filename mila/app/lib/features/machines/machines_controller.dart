// The machine list and lifecycle requests. Mutations are submitted once
// under a client-allocated request id and then only observed with
// `request show`, following `RequestPoll`.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../session.dart';

/// The offline snapshot cache; null keeps nothing on disk (tests, demo).
final snapshotStoreProvider = Provider<SnapshotStore?>((ref) => null);

/// The saved list for a deployment, if any, for offline entry points.
final savedSnapshotProvider = FutureProvider.family<MachineSnapshot?, Deployment>(
  (ref, deployment) async => ref.watch(snapshotStoreProvider)?.read(deployment),
);

/// Lifecycle actions offered on a machine.
enum MachineAction {
  start('start'),
  stop('stop'),
  pause('pause'),
  resume('resume'),
  pin('pin'),
  unpin('unpin'),
  delete('rm');

  const MachineAction(this.command);

  final String command;

  /// Actions that make sense for [machine], given its state and permissions.
  static List<MachineAction> available(Machine machine) {
    final manage = machine.permissions.manage;
    final write = machine.permissions.write;
    return [
      if (write && machine.observed == ObservedState.stopped) start,
      if (write && machine.observed == ObservedState.paused) resume,
      if (write && machine.observed == ObservedState.running) ...[pause, stop],
      if (machine.pinned) unpin else pin,
      if (manage && machine.owner && !machine.pinned) delete,
    ];
  }
}

/// Everything the machines screen shows.
final class MachinesView {
  const MachinesView({
    this.machines = const [],
    this.loading = false,
    this.failed = false,
    this.requests = const {},
    this.savedAt,
  });

  final List<Machine> machines;
  final bool loading;

  /// The last refresh failed; [machines] is the last good list.
  final bool failed;

  /// Tracked requests by machine id, and a new machine's under
  /// [newMachineRequest].
  final Map<String, RequestPoll> requests;

  /// Set while [machines] come from the offline snapshot rather than a
  /// listing read in this session: when that snapshot was saved.
  final DateTime? savedAt;

  MachinesView copyWith({
    List<Machine>? machines,
    bool? loading,
    bool? failed,
    Map<String, RequestPoll>? requests,
    DateTime? savedAt,
    bool live = false,
  }) => MachinesView(
    machines: machines ?? this.machines,
    loading: loading ?? this.loading,
    failed: failed ?? this.failed,
    requests: requests ?? this.requests,
    savedAt: live ? null : savedAt ?? this.savedAt,
  );
}

/// The [MachinesView.requests] key of a machine being created.
const String newMachineRequest = 'new';

/// Bytes in a gibibyte, the unit Porsche reads disk sizes in.
const int gibibyte = 1024 * 1024 * 1024;

/// Polls one request may use before Mila stops watching it.
const int maximumPolls = 120;

final machinesProvider = NotifierProvider.family<MachinesController, MachinesView, Deployment>(
  MachinesController.new,
);

final class MachinesController extends Notifier<MachinesView> {
  MachinesController(this.deployment);

  final Deployment deployment;
  bool _live = false;
  static const Backoff _backoff = Backoff(
    base: Duration(milliseconds: 500),
    cap: Duration(seconds: 5),
  );

  @override
  MachinesView build() {
    final session = ref.watch(sessionProvider(deployment));
    unawaited(_loadSnapshot());
    if (session != null) Future.microtask(refresh);
    return const MachinesView();
  }

  /// Shows the saved list until a live listing arrives.
  Future<void> _loadSnapshot() async {
    final store = ref.read(snapshotStoreProvider);
    if (store == null) return;
    final snapshot = await store.read(deployment);
    // A live listing that already landed wins over the snapshot.
    if (snapshot == null || _live) return;
    state = state.copyWith(machines: snapshot.machines, savedAt: snapshot.savedAt);
  }

  PorscheSession? get _session => ref.read(sessionProvider(deployment));

  /// Reloads the list; on failure keeps the last good list and marks it.
  Future<void> refresh() async {
    final session = _session;
    if (session == null) return;
    state = state.copyWith(loading: true);
    final outcome = await session.exec(PorscheCommand('ls', options: const {'json': true}));
    final reply = outcome.reply;
    if (reply is ReadReply) {
      try {
        final (listing, _) = decodeMachineList(reply.result);
        state = state.copyWith(
          machines: List.unmodifiable(listing.items.toList()..sort(compareMachines)),
          loading: false,
          failed: false,
          live: true,
        );
        _live = true;
        // A complete first page is the whole list for the snapshot; a
        // paginated listing is not cached rather than cached partially.
        final store = ref.read(snapshotStoreProvider);
        if (store != null && listing.nextCursor == null) {
          await store.write(
            MachineSnapshot(
              host: deployment.host,
              port: deployment.port,
              savedAt: ref.read(clockProvider)().toUtc(),
              machines: listing.items,
            ),
          );
        }
        return;
      } on MachineFormatException {
        // Falls through to the failed state below.
      }
    }
    state = state.copyWith(loading: false, failed: true);
  }

  /// Submits [action] on [machine] once and tracks it to a terminal state.
  Future<RequestPoll> perform(Machine machine, MachineAction action) {
    final spec = catalog[action.command]!;
    return _submit(
      machine.id,
      (requestId) => PorscheCommand(
        action.command,
        arguments: [machine.id],
        options: {'json': true, 'request-id': requestId, if (spec.physical) 'no-wait': true},
      ),
    );
  }

  /// Creates a machine; its progress is tracked under [newMachineRequest].
  /// Returns null without sending when a value would be refused.
  Future<RequestPoll?> create({String? name, String? source, MachineShape? shape}) => _submitBuilt(
    newMachineRequest,
    (requestId) => createMachineCommand(
      name: name,
      source: source,
      shape: shape ?? const MachineShape(),
      requestId: requestId,
    ),
  );

  /// Clones [machine]; progress is tracked on the source machine.
  Future<RequestPoll?> clone(Machine machine, {String? name}) => _submitBuilt(
    machine.id,
    (requestId) => cloneMachineCommand(machine.id, name: name, requestId: requestId),
  );

  /// Resizes [machine]; null without sending when nothing changes, the
  /// disk would shrink or a value would be refused.
  Future<RequestPoll?> resize(Machine machine, MachineShape shape) => _submitBuilt(
    machine.id,
    (requestId) => resizeMachineCommand(
      machine.id,
      shape,
      currentDiskGib: machine.diskBytes == null ? null : machine.diskBytes! ~/ gibibyte,
      requestId: requestId,
    ),
  );

  Future<RequestPoll?> _submitBuilt(String key, PorscheCommand? Function(String) build) async {
    final command = build(allocateRequestId(ref.read(randomProvider)));
    if (command == null) return null;
    return _submit(key, (_) => command);
  }

  /// Sends the command [build] makes under a fresh request id once, then
  /// observes it with `request show` until it is terminal, tracking it
  /// under [key].
  Future<RequestPoll> _submit(String key, PorscheCommand Function(String) build) async {
    final session = _session;
    if (session == null) {
      return RequestPoll.submitted('')
          .observe(const ChannelOutcome(PorscheExit.authority, ErrorReply(error: 'unauthorized')));
    }
    final command = build(allocateRequestId(ref.read(randomProvider)));
    final requestId = command.options['request-id']! as String;
    var poll = RequestPoll.submitted(requestId);
    _track(key, poll);
    poll = poll.observe(await session.exec(command));
    _track(key, poll);
    // A request still running after this many polls stays shown as accepted;
    // the next refresh reports its machine's state.
    while (!poll.terminal && poll.attempts < maximumPolls) {
      final next = poll.next as PollAgain;
      await Future<void>.delayed(_backoff.delay(next.attempt, ref.read(randomProvider)));
      poll = poll.polled();
      final outcome = await session.exec(
        PorscheCommand('request show', arguments: [requestId], options: const {'json': true}),
      );
      poll = poll.observe(outcome);
      _track(key, poll);
    }
    await refresh();
    return poll;
  }

  void _track(String machineId, RequestPoll poll) {
    state = state.copyWith(requests: Map.unmodifiable({...state.requests, machineId: poll}));
  }
}

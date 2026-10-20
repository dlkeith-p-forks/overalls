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
    this.controls = const {},
    this.savedAt,
    this.nextCursor,
    this.loadingMore = false,
    this.shown = const {},
    this.missing = const {},
  });

  final List<Machine> machines;
  final bool loading;

  /// The last refresh failed; [machines] is the last good list.
  final bool failed;

  /// Tracked requests by machine id, and a new machine's under
  /// [newMachineRequest].
  final Map<String, RequestPoll> requests;

  /// For a tracked clone or resize, by the same key as [requests]: the
  /// original request id that `request retry` and `request cancel` name.
  final Map<String, String> controls;

  /// Set while [machines] come from the offline snapshot rather than a
  /// listing read in this session: when that snapshot was saved.
  final DateTime? savedAt;

  /// Where the next `ls` page starts, when the listing has more.
  final String? nextCursor;
  final bool loadingMore;

  /// Machines read one at a time with `show` because no loaded page has
  /// them, such as one opened from a link.
  final Map<String, Machine> shown;

  /// Machine ids `show` reported as absent or not visible to the caller.
  final Set<String> missing;

  /// The machine with [id] from the list or a `show`, if loaded.
  Machine? find(String id) {
    for (final m in machines) {
      if (m.id == id) return m;
    }
    return shown[id];
  }

  MachinesView copyWith({
    List<Machine>? machines,
    bool? loading,
    bool? failed,
    Map<String, RequestPoll>? requests,
    Map<String, String>? controls,
    DateTime? savedAt,
    bool live = false,
    Object? nextCursor = _keep,
    bool? loadingMore,
    Map<String, Machine>? shown,
    Set<String>? missing,
  }) => MachinesView(
    machines: machines ?? this.machines,
    loading: loading ?? this.loading,
    failed: failed ?? this.failed,
    requests: requests ?? this.requests,
    controls: controls ?? this.controls,
    savedAt: live ? null : savedAt ?? this.savedAt,
    nextCursor: identical(nextCursor, _keep) ? this.nextCursor : nextCursor as String?,
    loadingMore: loadingMore ?? this.loadingMore,
    shown: shown ?? this.shown,
    missing: missing ?? this.missing,
  );
}

const Object _keep = Object();

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

  /// Reloads the first page; on failure keeps the last good list and
  /// marks it. Machines read with `show` that the page lacks are re-read.
  Future<void> refresh() async {
    final session = _session;
    if (session == null) return;
    state = state.copyWith(loading: true);
    final listing = await _page(session, null);
    if (listing == null) {
      state = state.copyWith(loading: false, failed: true);
      return;
    }
    final listed = {for (final m in listing.items) m.id};
    state = state.copyWith(
      machines: List.unmodifiable(listing.items.toList()..sort(compareMachines)),
      loading: false,
      failed: false,
      live: true,
      nextCursor: listing.nextCursor,
      shown: Map.unmodifiable({
        for (final e in state.shown.entries)
          if (!listed.contains(e.key)) e.key: e.value,
      }),
    );
    _live = true;
    for (final id in state.shown.keys.toList()) {
      unawaited(fetch(id, force: true));
    }
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
  }

  /// Appends the next `ls` page, if there is one.
  Future<void> more() async {
    final session = _session;
    final cursor = state.nextCursor;
    if (session == null || cursor == null || state.loadingMore) return;
    state = state.copyWith(loadingMore: true);
    final listing = await _page(session, cursor);
    if (listing == null) {
      state = state.copyWith(loadingMore: false, failed: true);
      return;
    }
    final byId = {for (final m in state.machines) m.id: m, for (final m in listing.items) m.id: m};
    state = state.copyWith(
      machines: List.unmodifiable(byId.values.toList()..sort(compareMachines)),
      loadingMore: false,
      failed: false,
      nextCursor: listing.nextCursor,
      shown: Map.unmodifiable({...state.shown}..removeWhere((id, _) => byId.containsKey(id))),
    );
  }

  Future<MachineListing?> _page(PorscheSession session, String? after) async {
    final ChannelOutcome outcome;
    try {
      outcome = await session.exec(PorscheCommand('ls', options: {'json': true, 'after': ?after}));
    } on Object {
      return null;
    }
    final reply = outcome.reply;
    if (reply is! ReadReply) return null;
    try {
      return decodeMachineList(reply.result).$1;
    } on MachineFormatException {
      return null;
    }
  }

  final Set<String> _fetching = {};

  /// Reads one machine with `show` when no loaded page has it. A refusal
  /// marks it missing; a transport failure leaves it to the next attempt.
  Future<void> fetch(String id, {bool force = false}) async {
    final session = _session;
    if (session == null || !isCanonicalUuid(id) || _fetching.contains(id)) return;
    if (!force && state.find(id) != null) return;
    _fetching.add(id);
    try {
      final outcome = await session.exec(
        PorscheCommand('show', arguments: [id], options: const {'json': true}),
      );
      final reply = outcome.reply;
      if (reply is ReadReply) {
        final machine = decodeMachine(reply.result);
        if (machine.id != id) return;
        state = state.copyWith(
          shown: Map.unmodifiable({...state.shown, id: machine}),
          missing: Set.unmodifiable({...state.missing}..remove(id)),
        );
      } else if (reply is ErrorReply) {
        state = state.copyWith(
          shown: Map.unmodifiable({...state.shown}..remove(id)),
          missing: Set.unmodifiable({...state.missing, id}),
        );
      }
    } on MachineFormatException {
      // An unreadable row is not shown half-decoded.
    } on Object {
      // Transport failure: the page offers Refresh.
    } finally {
      _fetching.remove(id);
    }
  }

  /// The images a new machine may start from; empty when unreadable.
  Future<List<ImageChoice>> images() async {
    final result = await _read(PorscheCommand('images', options: const {'json': true}));
    return result == null ? const [] : decodeImageChoices(result);
  }

  /// The caller's teams, first page; empty when unreadable.
  Future<List<TeamChoice>> teams() async {
    final result = await _read(PorscheCommand('team list', options: const {'json': true}));
    return result == null ? const [] : decodeTeamChoices(result).$1;
  }

  Future<Map<String, Object?>?> _read(PorscheCommand command) async {
    final session = _session;
    if (session == null) return null;
    try {
      final reply = (await session.exec(command)).reply;
      return reply is ReadReply ? reply.result : null;
    } on Object {
      return null;
    }
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
  Future<RequestPoll?> create({
    String? name,
    String? source,
    String? image,
    String? team,
    MachineShape? shape,
  }) => _submitBuilt(
    newMachineRequest,
    (requestId) => createMachineCommand(
      name: name,
      source: source,
      image: image,
      team: team,
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

  /// Retries or cancels the clone or resize tracked under [key]; null
  /// when nothing there can be controlled.
  Future<RequestPoll?> control(String key, RequestControl control) async {
    final original = state.controls[key];
    if (original == null) return null;
    final command = requestControlCommand(
      control,
      original,
      requestId: allocateRequestId(ref.read(randomProvider)),
    );
    if (command == null) return null;
    return _submit(key, (_) => command, control: original);
  }

  Future<RequestPoll?> _submitBuilt(String key, PorscheCommand? Function(String) build) async {
    final command = build(allocateRequestId(ref.read(randomProvider)));
    if (command == null) return null;
    return _submit(
      key,
      (_) => command,
      control: controllableCommands.contains(command.name)
          ? command.options['request-id']! as String
          : null,
    );
  }

  /// Each key's latest submission; an older one still polling stops
  /// updating what the key shows.
  final Map<String, int> _runs = {};

  /// Sends the command [build] makes under a fresh request id once, then
  /// observes it with `request show` until it is terminal, tracking it
  /// under [key]. [control] is the original request a retry or cancel
  /// names, kept so the request stays controllable.
  Future<RequestPoll> _submit(
    String key,
    PorscheCommand Function(String) build, {
    String? control,
  }) async {
    final session = _session;
    if (session == null) {
      return RequestPoll.submitted('')
          .observe(const ChannelOutcome(PorscheExit.authority, ErrorReply(error: 'unauthorized')));
    }
    final command = build(allocateRequestId(ref.read(randomProvider)));
    final requestId = command.options['request-id']! as String;
    final run = (_runs[key] ?? 0) + 1;
    _runs[key] = run;
    final controls = {...state.controls}..remove(key);
    state = state.copyWith(controls: Map.unmodifiable({...controls, key: ?control}));
    void track(RequestPoll poll) {
      if (_runs[key] == run) _track(key, poll);
    }

    var poll = RequestPoll.submitted(requestId);
    track(poll);
    poll = poll.observe(await session.exec(command));
    track(poll);
    // A request still running after this many polls stays shown as accepted;
    // the next refresh reports its machine's state.
    while (!poll.terminal && poll.attempts < maximumPolls && _runs[key] == run) {
      final next = poll.next as PollAgain;
      await Future<void>.delayed(_backoff.delay(next.attempt, ref.read(randomProvider)));
      poll = poll.polled();
      final outcome = await session.exec(
        PorscheCommand('request show', arguments: [requestId], options: const {'json': true}),
      );
      poll = poll.observe(outcome);
      track(poll);
    }
    await refresh();
    return poll;
  }

  void _track(String machineId, RequestPoll poll) {
    state = state.copyWith(requests: Map.unmodifiable({...state.requests, machineId: poll}));
  }
}

// Agent thread lists: one machine's threads and the deployment-wide Recent
// grid, with server-side unread counts, kept fresh by `watch`.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../mutation.dart';
import '../session.dart';

final class ThreadsView {
  const ThreadsView({this.threads = const [], this.loading = false, this.failed = false});

  /// Most recently updated first.
  final List<ThreadSummary> threads;
  final bool loading;
  final bool failed;

  ThreadsView copyWith({List<ThreadSummary>? threads, bool? loading, bool? failed}) => ThreadsView(
    threads: threads ?? this.threads,
    loading: loading ?? this.loading,
    failed: failed ?? this.failed,
  );
}

/// A deployment and, for one machine's list, the machine id.
typedef ThreadsKey = (Deployment, String? machine);

/// Pages Mila reads for one list before it stops.
const int maximumThreadPages = 4;

final threadsProvider = NotifierProvider.autoDispose
    .family<ThreadsController, ThreadsView, ThreadsKey>(ThreadsController.new);

final class ThreadsController extends Notifier<ThreadsView> {
  ThreadsController(this.key);

  final ThreadsKey key;
  WatchFeed? _feed;
  WatchFilter? _filter;
  Timer? _debounce;

  @override
  ThreadsView build() {
    ref.onDispose(() {
      _debounce?.cancel();
      unawaited(_feed?.close());
    });
    if (ref.watch(sessionProvider(key.$1)) != null) Future.microtask(refresh);
    return const ThreadsView();
  }

  Future<void> refresh() async {
    final session = ref.read(sessionProvider(key.$1));
    if (session == null) return;
    state = state.copyWith(loading: true);
    final threads = <ThreadSummary>[];
    String? after;
    var ok = true;
    for (var page = 0; page < maximumThreadPages; page++) {
      final result = await readResult(
        session,
        PorscheCommand('thread ls', options: {'json': true, 'machine': ?key.$2, 'after': ?after}),
      );
      if (result == null) {
        ok = false;
        break;
      }
      try {
        final (listing, _) = decodeThreadList(result);
        threads.addAll(listing.items);
        after = listing.nextCursor;
      } on ThreadFormatException {
        ok = false;
        break;
      }
      if (after == null) break;
    }
    if (!ref.mounted) return;
    if (!ok && threads.isEmpty) {
      state = state.copyWith(loading: false, failed: true);
      return;
    }
    final shown = threads.where((t) => !t.archived).toList()..sort(compareRecent);
    state = ThreadsView(threads: List.unmodifiable(shown));
    _watch(session, shown);
  }

  /// Watches the machine (if any) and the most recent threads, which is
  /// what the screen shows first; Porsche bounds each filter at 16.
  void _watch(PorscheSession session, List<ThreadSummary> shown) {
    final filter = WatchFilter(
      machines: [?key.$2],
      threads: shown.take(maximumWatchFilters).map((t) => t.id),
    );
    if (filter == _filter || filter.isEmpty) return;
    _filter = filter;
    unawaited(_feed?.close());
    final feed = WatchFeed(open: session.watch, filter: filter, random: ref.read(randomProvider));
    feed.events.listen((event) {
      if (event is ThreadChanged || event is Resync || event is MachineChanged) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 300), () => unawaited(refresh()));
      }
    });
    feed.start();
    _feed = feed;
  }

  /// Applies a read marker the thread screen just moved, without a reload.
  void markedRead(String threadId, UnreadState unread) {
    state = state.copyWith(
      threads: List.unmodifiable([
        for (final t in state.threads) t.id == threadId ? t.withUnread(t.unread.merge(unread)) : t,
      ]),
    );
  }
}

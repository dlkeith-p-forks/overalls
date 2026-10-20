import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../machines/machine_tabs.dart';
import '../failure_notice.dart';
import '../routes.dart';
import '../sign_in_screen.dart' show openExternalProvider;
import 'thread_labels.dart';
import 'threads_controller.dart';

/// One machine's agent threads.
class MachineThreadsScreen extends ConsumerStatefulWidget {
  const MachineThreadsScreen({super.key, required this.deployment, required this.machineId});

  final Deployment deployment;
  final String machineId;

  @override
  ConsumerState<MachineThreadsScreen> createState() => _MachineThreadsScreenState();
}

class _MachineThreadsScreenState extends ConsumerState<MachineThreadsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l = MilaLocalizations.of(context);
    final ThreadsKey key = (widget.deployment, widget.machineId);
    final view = ref.watch(threadsProvider(key));
    final shown = searchThreads(view.threads, _query);
    return MachineScaffold(
      deployment: widget.deployment,
      machineId: widget.machineId,
      tab: MachineTab.threads,
      actions: [
        TextButton(
          key: const Key('threads-refresh'),
          onPressed: ref.read(threadsProvider(key).notifier).refresh,
          child: Text(l.refresh.toUpperCase()),
        ),
      ],
      children: [
        TextField(
          key: const Key('threads-search'),
          decoration: InputDecoration(
            hintText: l.threadsSearch,
            prefixText: '${Glyph.search.char} ',
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        const SizedBox(height: MonoScale.line),
        if (view.failed)
          FailureNotice(
            message: l.threadsFailed,
            messageKey: const Key('threads-failed'),
            retryKey: const Key('threads-retry'),
            onRetry: ref.read(threadsProvider(key).notifier).refresh,
          ),
        if (!view.loading && !view.failed && view.threads.isEmpty) ...[
          Text(l.threadsEmpty),
          Text(
            l.threadsMachineEmptyHint,
            key: const Key('threads-empty-hint'),
            style: TextStyle(color: MonoTheme.of(context).textAlt),
          ),
        ],
        if (view.threads.isNotEmpty && shown.isEmpty) Text(l.threadsNoMatch),
        for (final thread in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: MonoScale.line / 2),
            child: ThreadCard(
              thread: thread,
              onTap: () =>
                  context.go(machineThreadPath(widget.deployment, widget.machineId, thread.id)),
            ),
          ),
      ],
    );
  }
}

/// Every thread on the deployment, most recent first, as a grid.
class RecentThreadsScreen extends ConsumerStatefulWidget {
  const RecentThreadsScreen({super.key, required this.deployment});

  final Deployment deployment;

  @override
  ConsumerState<RecentThreadsScreen> createState() => _RecentThreadsScreenState();
}

class _RecentThreadsScreenState extends ConsumerState<RecentThreadsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l = MilaLocalizations.of(context);
    final ThreadsKey key = (widget.deployment, null);
    final view = ref.watch(threadsProvider(key));
    final shown = searchThreads(view.threads, _query);
    final unread = totalUnread(view.threads);
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          key: const Key('recent-back'),
          onPressed: () => context.go(machinesPath(widget.deployment)),
          child: BackGlyph(label: l.back),
        ),
        title: Text(l.threadsRecentTitle),
        actions: [
          TextButton(
            key: const Key('recent-refresh'),
            onPressed: ref.read(threadsProvider(key).notifier).refresh,
            child: Text(l.refresh.toUpperCase()),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: ref.read(threadsProvider(key).notifier).refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(MonoScale.fontSize),
          children: [
            TextField(
              key: const Key('recent-search'),
              decoration: InputDecoration(
                hintText: l.threadsSearch,
                prefixText: '${Glyph.search.char} ',
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: MonoScale.line / 2),
            if (unread > 0)
              Text(
                l.threadsUnreadTotal(unread),
                key: const Key('recent-unread'),
                style: const TextStyle(fontWeight: MonoScale.bold),
              ),
            const SizedBox(height: MonoScale.line / 2),
            if (view.failed)
              FailureNotice(
                message: l.threadsFailed,
                messageKey: const Key('recent-failed'),
                retryKey: const Key('recent-retry'),
                onRetry: ref.read(threadsProvider(key).notifier).refresh,
              ),
            if (!view.loading && !view.failed && view.threads.isEmpty) ...[
              Text(l.threadsEmpty),
              Text(
                l.threadsEmptyHint,
                key: const Key('recent-empty-hint'),
                style: TextStyle(color: MonoTheme.of(context).textAlt),
              ),
              const SizedBox(height: MonoScale.line / 2),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ConsoleButton(
                  key: const Key('recent-start-browser'),
                  label: l.threadsStartInBrowser,
                  glyph: Glyph.arrowUpRight,
                  onPressed: () =>
                      ref.read(openExternalProvider)(newThreadInBrowser(widget.deployment)),
                ),
              ),
            ],
            if (view.threads.isNotEmpty && shown.isEmpty) Text(l.threadsNoMatch),
            LayoutBuilder(
              builder: (context, constraints) {
                // One card per 32 character cells, at least one column.
                final columns = (constraints.maxWidth / (MonoScale.fontSize * 0.6 * 32))
                    .floor()
                    .clamp(1, 4);
                final width = (constraints.maxWidth - (columns - 1) * MonoScale.fontSize) / columns;
                return Wrap(
                  spacing: MonoScale.fontSize,
                  runSpacing: MonoScale.line / 2,
                  children: [
                    for (final thread in shown)
                      SizedBox(
                        width: width,
                        child: ThreadCard(
                          thread: thread,
                          onTap: () => context.go(
                            thread.machineId == null
                                ? threadPath(widget.deployment, thread.id)
                                : machineThreadPath(
                                    widget.deployment,
                                    thread.machineId!,
                                    thread.id,
                                  ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The deployment's browser page for starting a thread; Porsche has no
/// command that creates one.
Uri newThreadInBrowser(Deployment deployment) =>
    Uri(scheme: 'https', host: deployment.host, path: '/threads/new');

/// A thread row: title, state and unread count, as text and weight.
class ThreadCard extends StatelessWidget {
  const ThreadCard({super.key, required this.thread, required this.onTap});

  final ThreadSummary thread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = MilaLocalizations.of(context);
    final tokens = MonoTheme.of(context);
    final unread = thread.unread.unread;
    return InkWell(
      key: Key('thread-${thread.id}'),
      onTap: onTap,
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              thread.title.isEmpty ? l.threadUntitled : thread.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: unread > 0 ? MonoScale.bold : MonoScale.medium,
                fontStyle: thread.title.isEmpty ? FontStyle.italic : FontStyle.normal,
              ),
            ),
            Wrap(
              spacing: MonoScale.fontSize,
              children: [
                StatusLabel(
                  threadStatusText(l, thread.status),
                  tone: threadStatusTone(thread.status),
                ),
                if (thread.mode != null)
                  Text(modeText(l, thread.mode!), style: TextStyle(color: tokens.textAlt)),
                if (unread > 0)
                  Text(
                    '${Glyph.bullet.char} ${l.threadUnread(unread)}',
                    key: Key('thread-unread-${thread.id}'),
                    style: const TextStyle(fontWeight: MonoScale.bold),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

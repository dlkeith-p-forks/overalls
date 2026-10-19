import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../routes.dart';
import 'thread_controller.dart';
import 'thread_labels.dart';

/// One agent thread: transcript, question, plan and composer. [machineId]
/// is set when the thread was opened from a machine's list.
class ThreadScreen extends ConsumerStatefulWidget {
  const ThreadScreen({super.key, required this.deployment, required this.threadId, this.machineId});

  final Deployment deployment;
  final String threadId;
  final String? machineId;

  @override
  ConsumerState<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends ConsumerState<ThreadScreen> {
  final TextEditingController _composer = TextEditingController();
  final TextEditingController _revision = TextEditingController();
  final Map<String, String?> _selected = {};
  final Map<String, TextEditingController> _answerText = {};

  @override
  void dispose() {
    _composer.dispose();
    _revision.dispose();
    for (final c in _answerText.values) {
      c.dispose();
    }
    super.dispose();
  }

  ThreadKey get _key => (widget.deployment, widget.threadId);

  TextEditingController _answerField(String id) =>
      _answerText.putIfAbsent(id, TextEditingController.new);

  Future<void> _send() async {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    if (await ref.read(threadProvider(_key).notifier).prompt(text)) _composer.clear();
  }

  Future<void> _answer(PendingQuestion pending) async {
    final answers = {
      for (final q in pending.questions)
        q.id: QuestionAnswer(selected: _selected[q.id], text: _answerField(q.id).text),
    };
    if (await ref.read(threadProvider(_key).notifier).answer(answers)) {
      _selected.clear();
      for (final c in _answerText.values) {
        c.clear();
      }
    }
  }

  Future<void> _revise() async {
    if (await ref.read(threadProvider(_key).notifier).revisePlan(_revision.text)) {
      _revision.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = MilaLocalizations.of(context);
    final tokens = MonoTheme.of(context);
    final view = ref.watch(threadProvider(_key));
    final controller = ref.read(threadProvider(_key).notifier);
    final detail = view.detail;
    final summary = detail?.summary;
    final machineId = widget.machineId ?? summary?.machineId;
    final back = machineId == null
        ? threadsPath(widget.deployment)
        : machineThreadsPath(widget.deployment, machineId);
    final busy = detail?.busy ?? false;
    final plan = detail?.latestPlan;
    final pending = detail?.pendingQuestion;
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          key: const Key('thread-back'),
          onPressed: () => context.go(back),
          child: BackGlyph(label: l.back),
        ),
        title: Text(
          summary == null || summary.title.isEmpty ? l.threadUntitled : summary.title,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            key: const Key('thread-refresh'),
            onPressed: controller.refresh,
            child: Text(l.refresh.toUpperCase()),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              key: const Key('thread-transcript'),
              padding: const EdgeInsets.all(MonoScale.fontSize),
              children: [
                if (view.failed) Text(l.threadFailed, key: const Key('thread-failed')),
                if (summary != null)
                  Wrap(
                    spacing: MonoScale.fontSize,
                    children: [
                      StatusLabel(
                        threadStatusText(l, summary.status),
                        tone: threadStatusTone(summary.status),
                      ),
                      if (busy) StatusLabel(l.threadWorking, tone: StateTone.pending),
                      if (summary.failureReason != null)
                        Text(summary.failureReason!, textDirection: TextDirection.ltr),
                    ],
                  ),
                const SizedBox(height: MonoScale.line / 2),
                if (!view.loading && view.turns.isEmpty) Text(l.threadNoTurns),
                for (final turn in view.turns) _Turn(turn: turn, key: Key('turn-${turn.sequence}')),
                if (plan != null && !plan.implemented) ...[
                  const SizedBox(height: MonoScale.line / 2),
                  Panel(
                    key: const Key('thread-plan'),
                    title: l.threadPlanTitle,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SelectableText(plan.text),
                        const SizedBox(height: MonoScale.line / 2),
                        TextField(
                          key: const Key('plan-revision'),
                          controller: _revision,
                          minLines: 1,
                          maxLines: 6,
                          decoration: InputDecoration(hintText: l.threadPlanRevisionHint),
                        ),
                        const SizedBox(height: MonoScale.line / 2),
                        Wrap(
                          spacing: MonoScale.fontSize / 2,
                          children: [
                            ConsoleButton(
                              key: const Key('plan-approve'),
                              label: l.threadPlanApprove,
                              onPressed: view.sending || busy ? null : controller.approvePlan,
                            ),
                            ConsoleButton(
                              key: const Key('plan-revise'),
                              label: l.threadPlanRevise,
                              onPressed: view.sending || busy ? null : _revise,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
                if (pending != null) ...[
                  const SizedBox(height: MonoScale.line / 2),
                  Panel(
                    key: const Key('thread-question'),
                    title: l.threadQuestionTitle,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final q in pending.questions) ...[
                          if (q.header.isNotEmpty)
                            Text(q.header, style: const TextStyle(fontWeight: MonoScale.bold)),
                          Text(q.question),
                          if (q.options.isNotEmpty)
                            Segmented<String>(
                              keyPrefix: 'answer-${q.id}',
                              options: [for (final o in q.options) o.label],
                              selected: _selected[q.id],
                              label: (label) => label,
                              onSelected: (label) => setState(
                                () => _selected[q.id] = _selected[q.id] == label ? null : label,
                              ),
                            ),
                          for (final o in q.options)
                            if (o.description.isNotEmpty && _selected[q.id] == o.label)
                              Text(o.description, style: TextStyle(color: tokens.textAlt)),
                          TextField(
                            key: Key('answer-text-${q.id}'),
                            controller: _answerField(q.id),
                            decoration: InputDecoration(hintText: l.threadAnswerHint),
                          ),
                          const SizedBox(height: MonoScale.line / 2),
                        ],
                        ConsoleButton(
                          key: const Key('answer-send'),
                          label: l.threadAnswerSend,
                          onPressed: view.sending ? null : () => _answer(pending),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (view.failure != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MonoScale.fontSize),
              child: Text(
                _failureText(l, view.failure!),
                key: const Key('thread-action-failed'),
                style: const TextStyle(fontWeight: MonoScale.bold),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: tokens.text, width: MonoScale.border),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(MonoScale.fontSize / 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Segmented<CollaborationMode>(
                    keyPrefix: 'thread-mode',
                    options: CollaborationMode.values,
                    selected: summary?.mode,
                    label: (mode) => modeText(l, mode),
                    onSelected: view.sending || busy || summary == null
                        ? null
                        : (mode) {
                            if (mode != summary.mode) controller.setMode(mode);
                          },
                  ),
                  const SizedBox(height: MonoScale.line / 4),
                  TextField(
                    key: const Key('thread-composer'),
                    controller: _composer,
                    minLines: 1,
                    maxLines: 6,
                    decoration: InputDecoration(
                      hintText: busy ? l.threadComposerBusy : l.threadComposerHint,
                    ),
                  ),
                  const SizedBox(height: MonoScale.line / 4),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: ConsoleButton(
                      key: const Key('thread-send'),
                      label: l.threadSend,
                      glyph: Glyph.returnKey,
                      onPressed: view.sending || busy || summary == null ? null : _send,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _failureText(MilaLocalizations l, ThreadActionFailure failure) => switch (failure) {
    ThreadActionFailure.refused => l.requestRefused,
    ThreadActionFailure.failed => l.requestFailed,
    ThreadActionFailure.invalidText => l.threadTextInvalid,
    ThreadActionFailure.tooLarge => l.threadTextTooLarge,
    ThreadActionFailure.busy => l.threadBusy,
  };
}

class _Turn extends StatelessWidget {
  const _Turn({super.key, required this.turn});

  final TurnEvent turn;

  @override
  Widget build(BuildContext context) {
    final l = MilaLocalizations.of(context);
    final tokens = MonoTheme.of(context);
    final text = turn.text;
    if (text == null) {
      return Text(
        '${Glyph.caretRight.char} ${eventText(l, turn.kind)}',
        style: TextStyle(color: tokens.textAlt, fontStyle: FontStyle.italic),
      );
    }
    final mine = turn.kind == TurnEventKind.prompt;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MonoScale.line / 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            mine ? l.threadYou : l.threadAgent,
            style: TextStyle(color: tokens.textAlt, fontWeight: MonoScale.bold),
          ),
          // Agent text is shown as written; a selectable block lets it be
          // copied, never interpreted.
          SelectableText(text),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../machines/machine_tabs.dart';
import '../routes.dart';
import 'terminal_controller.dart';

/// One shared terminal session. The emulator and every identifier stay left
/// to right in right-to-left locales; the surrounding chrome follows the
/// locale.
class TerminalScreen extends ConsumerWidget {
  const TerminalScreen({
    super.key,
    required this.deployment,
    required this.machineId,
    required this.sessionId,
  });

  final Deployment deployment;
  final String machineId;
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final tokens = MonoTheme.of(context);
    final key = (deployment, machineId, sessionId);
    final view = ref.watch(terminalProvider(key));
    final controller = ref.read(terminalProvider(key).notifier);
    final attach = view.attach;
    final status = switch (attach.phase) {
      AttachPhase.idle || AttachPhase.attaching => (l.terminalAttaching, StateTone.pending),
      AttachPhase.attached => (
        attach.readOnly ? l.terminalReadOnly : l.terminalLive,
        attach.readOnly ? null : StateTone.success,
      ),
      AttachPhase.waiting => (l.terminalReconnecting, StateTone.pending),
      AttachPhase.ended => (_endedText(l, attach), StateTone.danger),
    };
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          key: const Key('terminal-back'),
          onPressed: () => context.go(machineTerminalsPath(deployment, machineId)),
          child: BackGlyph(label: l.back),
        ),
        title: Text(
          '${machineName(ref, deployment, machineId)} ${Glyph.arrowRight.char} ${sessionId.substring(0, 8)}',
          textDirection: TextDirection.ltr,
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MonoScale.fontSize,
              vertical: MonoScale.line / 4,
            ),
            child: Wrap(
              spacing: MonoScale.fontSize,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusLabel(status.$1, key: const Key('terminal-status'), tone: status.$2),
                Segmented<bool>(
                  keyPrefix: 'terminal-mode',
                  options: const [false, true],
                  selected: attach.readOnlyRequested,
                  label: (ro) => ro ? l.terminalModeView : l.terminalModeControl,
                  onSelected: (ro) => controller.setReadOnly(ro),
                ),
                if (attach.phase == AttachPhase.ended)
                  ConsoleButton(
                    key: const Key('terminal-retry'),
                    label: l.retry,
                    onPressed: controller.retry,
                  ),
              ],
            ),
          ),
          Expanded(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.symmetric(
                    horizontal: BorderSide(color: tokens.text, width: MonoScale.border),
                  ),
                ),
                child: TerminalView(
                  controller.terminal,
                  key: const Key('terminal-view'),
                  theme: monoTerminalTheme(tokens),
                  textStyle: const TerminalStyle(
                    fontFamily: MonoScale.fontFamily,
                    fontFamilyFallback: MonoScale.fontFamilyFallback,
                    fontSize: MonoScale.fontSize - 1,
                    height: MonoScale.lineHeight,
                  ),
                  padding: const EdgeInsets.all(MonoScale.fontSize / 2),
                  readOnly: !attach.canSendInput,
                  autofocus: true,
                  keyboardAppearance: Theme.of(context).brightness,
                ),
              ),
            ),
          ),
          Directionality(
            textDirection: TextDirection.ltr,
            child: ExtraKeysRow(
              ctrl: view.keys.ctrl,
              enabled: attach.canSendInput,
              onKey: controller.press,
            ),
          ),
        ],
      ),
    );
  }

  String _endedText(MilaLocalizations l, TerminalAttach attach) => switch (attach.outcome) {
    AttachOutcome.closed || null => l.terminalEnded,
    AttachOutcome.refused => l.terminalRefused,
    AttachOutcome.authority => l.terminalSignedOut,
    AttachOutcome.invalid => l.terminalInvalid,
    AttachOutcome.transport => l.terminalUnreachable,
  };
}

/// ESC TAB CTRL ~ | - arrows PASTE, as terminal keys a phone lacks. The
/// labels are terminal key names, the same in every locale, except PASTE.
class ExtraKeysRow extends StatelessWidget {
  const ExtraKeysRow({super.key, required this.ctrl, required this.enabled, required this.onKey});

  final bool ctrl;
  final bool enabled;
  final void Function(ExtraKey key) onKey;

  @override
  Widget build(BuildContext context) {
    final l = MilaLocalizations.of(context);
    final tokens = MonoTheme.of(context);
    String label(ExtraKey key) => switch (key) {
      ExtraKey.esc => 'ESC',
      ExtraKey.tab => 'TAB',
      ExtraKey.ctrl => 'CTRL',
      ExtraKey.tilde => '~',
      ExtraKey.pipe => '|',
      ExtraKey.dash => '-',
      ExtraKey.up => Glyph.arrowUp.char,
      ExtraKey.down => Glyph.arrowDown.char,
      ExtraKey.left => Glyph.arrowLeft.char,
      ExtraKey.right => Glyph.arrowRight.char,
      ExtraKey.paste => l.terminalPaste.toUpperCase(),
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final key in ExtraKey.values)
            Semantics(
              button: true,
              toggled: key == ExtraKey.ctrl ? ctrl : null,
              child: TextButton(
                key: Key('extra-${key.name}'),
                style: key == ExtraKey.ctrl && ctrl
                    ? TextButton.styleFrom(
                        backgroundColor: tokens.text,
                        foregroundColor: tokens.background,
                      )
                    : null,
                onPressed: enabled ? () => onKey(key) : null,
                child: Text(label(key), softWrap: false),
              ),
            ),
        ],
      ),
    );
  }
}

// Localized text for closed thread values.
import 'package:mila_core/mila_core.dart';

import '../../l10n/app_localizations.dart';

String threadStatusText(MilaLocalizations l, ThreadStatus? status) => switch (status) {
  ThreadStatus.pending => l.statePending,
  ThreadStatus.provisioning => l.threadStatusProvisioning,
  ThreadStatus.ready => l.threadStatusReady,
  ThreadStatus.failed => l.stateFailed,
  ThreadStatus.deleting => l.stateDeleting,
  ThreadStatus.archived => l.threadStatusArchived,
  null => l.stateUnknown,
};

StateTone? threadStatusTone(ThreadStatus? status) => switch (status) {
  ThreadStatus.pending || ThreadStatus.provisioning || ThreadStatus.deleting => StateTone.pending,
  ThreadStatus.failed => StateTone.danger,
  ThreadStatus.ready => StateTone.success,
  ThreadStatus.archived || null => null,
};

String modeText(MilaLocalizations l, CollaborationMode mode) => switch (mode) {
  CollaborationMode.plan => l.threadModePlan,
  CollaborationMode.work => l.threadModeWork,
};

/// A short label for a transcript event that carries no text.
String eventText(MilaLocalizations l, TurnEventKind? kind) => switch (kind) {
  TurnEventKind.prompt => l.threadEventPrompt,
  TurnEventKind.assistant || TurnEventKind.modelOutput => l.threadEventAssistant,
  TurnEventKind.turnStarted => l.threadEventTurnStarted,
  TurnEventKind.turnFinished => l.threadEventTurnFinished,
  TurnEventKind.turnFailed => l.threadEventTurnFailed,
  TurnEventKind.toolQueued || TurnEventKind.toolResult => l.threadEventTool,
  TurnEventKind.childSpawned => l.threadEventChild,
  TurnEventKind.waitingForVm => l.threadEventWaitingForMachine,
  TurnEventKind.questionsRequested => l.threadEventQuestions,
  TurnEventKind.questionsAnswered => l.threadEventAnswered,
  TurnEventKind.questionsCancelled => l.threadEventQuestionsCancelled,
  TurnEventKind.planProposed => l.threadEventPlan,
  TurnEventKind.contextCaptured ||
  TurnEventKind.contextCompacted ||
  TurnEventKind.maintenanceFinished => l.threadEventMaintenance,
  null => l.threadEventOther,
};

// Maps closed domain values to localized text.
import 'package:mila_core/mila_core.dart';

import '../l10n/app_localizations.dart';
import 'machines/machines_controller.dart';

extension StateLabelText on StateLabel {
  String text(MilaLocalizations l) => switch (this) {
    StateLabel.deleting => l.stateDeleting,
    StateLabel.stopping => l.stateStopping,
    StateLabel.suspending => l.stateSuspending,
    StateLabel.resuming => l.stateResuming,
    StateLabel.starting => l.stateStarting,
    StateLabel.pending => l.statePending,
    StateLabel.running => l.stateRunning,
    StateLabel.stopped => l.stateStopped,
    StateLabel.paused => l.statePaused,
    StateLabel.failed => l.stateFailed,
    StateLabel.deleted => l.stateDeleted,
    StateLabel.unknown => l.stateUnknown,
    StateLabel.unavailable => l.stateUnavailable,
  };
}

extension MachineActionText on MachineAction {
  String text(MilaLocalizations l) => switch (this) {
    MachineAction.start => l.actionStart,
    MachineAction.stop => l.actionStop,
    MachineAction.pause => l.actionPause,
    MachineAction.resume => l.actionResume,
    MachineAction.pin => l.actionPin,
    MachineAction.unpin => l.actionUnpin,
    MachineAction.delete => l.actionDelete,
  };
}

extension RequestPollText on RequestPoll {
  String text(MilaLocalizations l) => switch (phase) {
    PollPhase.submitting || PollPhase.uncertain || PollPhase.accepted => l.requestWaiting,
    PollPhase.succeeded => l.requestSucceeded,
    PollPhase.failed => l.requestFailed,
    PollPhase.refused => l.requestRefused,
  };
}

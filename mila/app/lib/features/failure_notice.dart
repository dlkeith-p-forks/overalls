import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';

/// A failure message with the way out beside it: a Try again button that
/// repeats the read that failed.
class FailureNotice extends StatelessWidget {
  const FailureNotice({
    super.key,
    required this.message,
    required this.onRetry,
    this.messageKey,
    this.retryKey,
  });

  final String message;
  final VoidCallback onRetry;

  /// Keys the message text, for screens whose tests already find it by key.
  final Key? messageKey;
  final Key? retryKey;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: MonoScale.line / 2),
    child: Wrap(
      spacing: MonoScale.fontSize,
      runSpacing: MonoScale.line / 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(message, key: messageKey),
        ConsoleButton(
          key: retryKey,
          label: MilaLocalizations.of(context).retry,
          onPressed: onRetry,
        ),
      ],
    ),
  );
}

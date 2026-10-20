#ifndef RUNNER_MILA_PUSH_H_
#define RUNNER_MILA_PUSH_H_

#include <functional>
#include <optional>
#include <string>

// WNS through the Windows App SDK (ADR-0236): the channel URI Mila exchanges
// with Susan for a push key, raw pokes opened natively into a notification
// with fixed localized text, and notification clicks turned into links.
//
// Built only with `MILA_WINDOWS_APP_SDK_DIR` (and `MILA_WNS_REMOTE_ID`, the
// Entra ID application id WNS issues channels for); otherwise every call
// reports push as unavailable and the runner still builds and works. Push
// also needs package identity: the MSIX layout, registered in dev with
// `Add-AppxPackage -Register`.
namespace mila_push {

enum class Launch {
  kContinue,  // Start the window.
  kExit,      // A push activation was handled in the background.
};

// Registers for notifications and push, and handles the activation this
// process was started for. A notification click's link is written to
// [link]; a raw push is opened and shown, and the process should exit.
Launch Start(std::optional<std::string>& link);

// Whether this build and package can use WNS.
bool Available();

// Requests a channel; [done] runs once, on any thread, with the channel URI
// or nothing. The URI is a bearer secret for WNS: never logged.
void RequestChannel(std::function<void(std::optional<std::string>)> done);

// Links from notification clicks while the app runs; [on_link] runs on any
// thread.
void OnLink(std::function<void(std::string)> on_link);

void Stop();

}  // namespace mila_push

#endif  // RUNNER_MILA_PUSH_H_

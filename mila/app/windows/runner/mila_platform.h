#ifndef RUNNER_MILA_PLATFORM_H_
#define RUNNER_MILA_PLATFORM_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

// The `dev.overalls.mila/platform` channel on Windows (ADR-0220, ADR-0235),
// with the same methods as the darwin runners: CNG device keys
// (`device_keys.h`), DPAPI-sealed poke keys (`poke_keys.h`), WNS channel
// URIs (`mila_push.h`), the owner-only data directory, `overalls://` links
// from the command line, a second instance or a notification, and HTTPS
// links to the default browser or the clipboard. Private keys never cross.
class MilaPlatform {
 public:
  static constexpr char kChannel[] = "dev.overalls.mila/platform";
  // Posted to the window to run a callback on the platform thread.
  static constexpr UINT kRunMessage = WM_APP + 0x4d;

  MilaPlatform(flutter::BinaryMessenger* messenger, HWND window,
               std::optional<std::string> initial_link);
  ~MilaPlatform();

  MilaPlatform(const MilaPlatform&) = delete;
  MilaPlatform& operator=(const MilaPlatform&) = delete;

  // A link from a second instance or a notification click; platform thread.
  void Open(const std::string& link);

  // Runs a callback posted with kRunMessage; returns whether it was one.
  static bool HandleRun(UINT message, LPARAM lparam);

 private:
  using Result = std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call, Result result);
  void RequestToken(Result result);
  void ReceivedToken(std::optional<std::string> token);
  // Runs [task] on the platform thread, from any thread.
  void Post(std::function<void()> task);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  // The link the app was launched with, until Dart asks for it.
  std::optional<std::string> initial_link_;
  // Whether Dart has asked for the launch link; later links are pushed.
  bool initial_link_taken_ = false;
  // `push.token` calls waiting for WNS.
  std::vector<Result> pending_tokens_;
  // The last channel URI handed to Dart, to notice rotation. Never logged.
  std::optional<std::string> last_token_;
  // Cleared on destruction so late WNS callbacks are dropped.
  std::shared_ptr<bool> alive_;
};

#endif  // RUNNER_MILA_PLATFORM_H_

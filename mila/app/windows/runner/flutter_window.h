#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <optional>
#include <string>

#include "mila_platform.h"
#include "win32_window.h"

// A window hosting the Flutter view and Mila's platform channel.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|;
  // |initial_link| is the `overalls://` link the process was launched with.
  FlutterWindow(const flutter::DartProject& project,
                std::optional<std::string> initial_link);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::optional<std::string> initial_link_;
  std::unique_ptr<MilaPlatform> platform_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <optional>
#include <string>

#include "flutter_window.h"
#include "mila_push.h"
#include "mila_text.h"
#include "single_instance.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // An `overalls://` link from the shell (the MSIX protocol handler passes
  // it as an argument), or from a notification click or protocol activation.
  std::optional<std::string> link;
  for (const std::string& argument : command_line_arguments) {
    if (mila_text::ValidLink(argument)) link = argument;
  }
  // A raw push that activated this process is opened and shown without a
  // window.
  if (mila_push::Start(link) == mila_push::Launch::kExit) {
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }
  if (!single_instance::Claim(link)) {
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, std::move(link));
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Mila", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  mila_push::Stop();
  ::CoUninitialize();
  return EXIT_SUCCESS;
}

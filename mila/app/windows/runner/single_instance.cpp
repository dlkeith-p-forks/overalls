#include "single_instance.h"

#include "mila_text.h"

namespace single_instance {
namespace {

constexpr wchar_t kMutex[] = L"Local\\dev.overalls.mila.instance";
// The class and title `Win32Window` registers for the runner window.
constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"Mila";

}  // namespace

bool Claim(const std::optional<std::string>& link) {
  // Deliberately never closed: the mutex lives as long as the instance.
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, kMutex);
  if (mutex != nullptr && ::GetLastError() != ERROR_ALREADY_EXISTS) return true;
  if (mutex != nullptr) ::CloseHandle(mutex);
  // The first instance may still be creating its window.
  HWND window = nullptr;
  for (int attempt = 0; attempt < 50 && window == nullptr; ++attempt) {
    window = ::FindWindowW(kWindowClass, kWindowTitle);
    if (window == nullptr) ::Sleep(100);
  }
  if (window == nullptr) return false;
  if (link && mila_text::ValidLink(*link)) {
    COPYDATASTRUCT data{kLinkMessage, static_cast<DWORD>(link->size()),
                        const_cast<char*>(link->data())};
    DWORD_PTR ignored = 0;
    ::SendMessageTimeoutW(window, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data),
                          SMTO_ABORTIFHUNG, 5000, &ignored);
  }
  DWORD process = 0;
  ::GetWindowThreadProcessId(window, &process);
  ::AllowSetForegroundWindow(process);
  if (::IsIconic(window)) ::ShowWindow(window, SW_RESTORE);
  ::SetForegroundWindow(window);
  return false;
}

std::optional<std::string> LinkFrom(LPARAM lparam) {
  const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
  if (data == nullptr || data->dwData != kLinkMessage || data->cbData > 2048 ||
      data->lpData == nullptr) {
    return std::nullopt;
  }
  std::string link(static_cast<const char*>(data->lpData), data->cbData);
  if (!mila_text::ValidLink(link)) return std::nullopt;
  return link;
}

}  // namespace single_instance

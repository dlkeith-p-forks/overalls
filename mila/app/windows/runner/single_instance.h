#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <optional>
#include <string>

// One Mila window per user session. A second launch (an `overalls://` link
// from the shell, or the Start menu) hands its link to the running window
// with WM_COPYDATA and exits; the running window only navigates.
namespace single_instance {

// WM_COPYDATA `dwData` for a forwarded link.
constexpr ULONG_PTR kLinkMessage = 0x4d494c41;  // "MILA"

// True when this process is the first instance (and owns the session's
// instance mutex until exit); otherwise forwards [link], if any, to the
// running window and returns false.
bool Claim(const std::optional<std::string>& link);

// A forwarded link from a WM_COPYDATA message, if the message is one.
std::optional<std::string> LinkFrom(LPARAM lparam);

}  // namespace single_instance

#endif  // RUNNER_SINGLE_INSTANCE_H_

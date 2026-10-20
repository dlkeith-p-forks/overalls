#ifndef RUNNER_NOTIFICATION_TEXT_H_
#define RUNNER_NOTIFICATION_TEXT_H_

#include <string>

// @cc [owner:ghuntley,label:security;privacy] mila-native-notification-fixed-text
// A notification MUST carry only the fixed localized title and body and, for
// an authentic poke, the `overalls://` link of its route. It MUST NOT show or
// log poke bytes, plaintext, keys or tokens.
namespace notification_text {

struct Text {
  std::wstring title;
  std::wstring body;
};

// The generated strings (`strings.g.h`) for the user's preferred UI
// languages: an exact tag first, then its language and script, then its
// language, then English.
Text ForUser();

}  // namespace notification_text

#endif  // RUNNER_NOTIFICATION_TEXT_H_

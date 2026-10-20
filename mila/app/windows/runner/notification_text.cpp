#include "notification_text.h"

#include <windows.h>

#include <vector>

#include "strings.g.h"

namespace notification_text {
namespace {

const mila_strings::NotificationText* Find(const std::wstring& tag) {
  for (const auto& text : mila_strings::kNotificationTexts) {
    if (::CompareStringOrdinal(text.locale, -1, tag.c_str(), -1, TRUE) == CSTR_EQUAL) return &text;
  }
  return nullptr;
}

// `zh-Hans-CN` -> `zh-Hans-CN`, `zh-Hans`, `zh`.
const mila_strings::NotificationText* Match(std::wstring tag) {
  while (!tag.empty()) {
    if (const auto* text = Find(tag)) return text;
    const size_t dash = tag.rfind(L'-');
    if (dash == std::wstring::npos) break;
    tag.resize(dash);
  }
  return nullptr;
}

std::vector<std::wstring> PreferredLanguages() {
  ULONG count = 0;
  ULONG size = 0;
  std::vector<std::wstring> tags;
  if (!::GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, nullptr, &size) || size == 0) {
    return tags;
  }
  std::vector<wchar_t> buffer(size);
  if (!::GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, buffer.data(), &size)) return tags;
  for (const wchar_t* p = buffer.data(); *p != L'\0'; p += wcslen(p) + 1) tags.emplace_back(p);
  return tags;
}

}  // namespace

Text ForUser() {
  for (const std::wstring& tag : PreferredLanguages()) {
    if (const auto* text = Match(tag)) return {text->title, text->body};
  }
  const auto* english = Find(L"en");
  return {english->title, english->body};
}

}  // namespace notification_text

#include "mila_text.h"

#include <windows.h>

namespace mila_text {

std::wstring Wide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int size = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                                         static_cast<int>(utf8.size()), nullptr, 0);
  if (size <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), static_cast<int>(utf8.size()),
                        out.data(), size);
  return out;
}

std::string Utf8(const std::wstring& utf16) {
  if (utf16.empty()) return std::string();
  const int size = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, utf16.data(),
                                         static_cast<int>(utf16.size()), nullptr, 0, nullptr,
                                         nullptr);
  if (size <= 0) return std::string();
  std::string out(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, utf16.data(),
                        static_cast<int>(utf16.size()), out.data(), size, nullptr, nullptr);
  return out;
}

bool ValidHost(const std::string& host) {
  if (host.empty() || host.size() > 253) return false;
  size_t labels = 0;
  size_t start = 0;
  while (start <= host.size()) {
    size_t end = host.find('.', start);
    if (end == std::string::npos) end = host.size();
    const size_t length = end - start;
    if (length == 0 || length > 63) return false;
    if (host[start] == '-' || host[end - 1] == '-') return false;
    for (size_t i = start; i < end; ++i) {
      const char c = host[i];
      if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
    }
    ++labels;
    start = end + 1;
  }
  return labels >= 2;
}

namespace {

bool Printable(const std::string& text) {
  for (const char c : text) {
    const unsigned char byte = static_cast<unsigned char>(c);
    if (byte <= 0x20 || byte == 0x7f) return false;
  }
  return true;
}

}  // namespace

bool ValidLink(const std::string& link) {
  return link.rfind("overalls://", 0) == 0 && link.size() <= 2048 && Printable(link);
}

bool ValidHttps(const std::string& url) {
  const std::string scheme = "https://";
  if (url.rfind(scheme, 0) != 0 || url.size() > 4096 || !Printable(url)) return false;
  const size_t end = url.find_first_of("/?#", scheme.size());
  std::string authority = url.substr(scheme.size(), end == std::string::npos
                                                        ? std::string::npos
                                                        : end - scheme.size());
  if (authority.find('@') != std::string::npos) return false;
  const size_t colon = authority.find(':');
  if (colon != std::string::npos) {
    const std::string port = authority.substr(colon + 1);
    if (port.empty() || port.size() > 5) return false;
    for (const char c : port) {
      if (c < '0' || c > '9') return false;
    }
    authority.resize(colon);
  }
  return ValidHost(authority);
}

}  // namespace mila_text

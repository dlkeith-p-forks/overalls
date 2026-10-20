#ifndef RUNNER_MILA_TEXT_H_
#define RUNNER_MILA_TEXT_H_

#include <optional>
#include <string>

// Text checks shared by the platform channel, the poke keys and the link
// forwarding, matching `darwin/Shared/MilaKeys.swift` and `mila_core`.
namespace mila_text {

// UTF-8 <-> UTF-16 for Win32 calls; empty on invalid input.
std::wstring Wide(const std::string& utf8);
std::string Utf8(const std::wstring& utf16);

// A lower-case DNS hostname, as `mila_core`'s `isHostname`: at most 253
// bytes, at least two labels of [a-z0-9-], no label starting or ending with
// '-' or longer than 63.
bool ValidHost(const std::string& host);

// An `overalls://` link of at most 2048 bytes with no control characters.
bool ValidLink(const std::string& link);

// An `https://` URL whose host passes ValidHost (an optional :port is
// allowed), with no userinfo, spaces or control characters.
bool ValidHttps(const std::string& url);

}  // namespace mila_text

#endif  // RUNNER_MILA_TEXT_H_

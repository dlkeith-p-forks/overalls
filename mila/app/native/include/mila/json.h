#pragma once

#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace mila {

// A strict RFC 8259 JSON value, for poke plaintexts and push payloads. It
// refuses duplicate object keys, trailing input, control characters in
// strings, lone surrogates and nesting deeper than 32. Numbers keep their
// text so callers can require an exact integer.
struct Json {
  enum class Type { kNull, kBool, kNumber, kString, kArray, kObject };

  Type type = Type::kNull;
  bool boolean = false;
  std::string text;  // A string's UTF-8 value, or a number's literal text.
  std::vector<Json> array;
  std::vector<std::pair<std::string, Json>> object;

  // The member [key] of an object, or nullptr.
  const Json* Find(const std::string& key) const;
  // Whether this is the integer literal [value] (no fraction or exponent).
  bool IsInteger(long long value) const;
};

std::optional<Json> ParseJson(const std::string& input);

}  // namespace mila

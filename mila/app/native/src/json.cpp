#include "mila/json.h"

#include <cstdint>

namespace mila {
namespace {

constexpr int kMaximumDepth = 32;

class Parser {
 public:
  explicit Parser(const std::string& input) : input_(input) {}

  std::optional<Json> Document() {
    std::optional<Json> value = Value(0);
    Space();
    if (!value || position_ != input_.size()) return std::nullopt;
    return value;
  }

 private:
  void Space() {
    while (position_ < input_.size()) {
      const char c = input_[position_];
      if (c != ' ' && c != '\t' && c != '\n' && c != '\r') return;
      ++position_;
    }
  }

  bool Literal(const char* word) {
    size_t i = 0;
    for (; word[i] != '\0'; ++i) {
      if (position_ + i >= input_.size() || input_[position_ + i] != word[i]) return false;
    }
    position_ += i;
    return true;
  }

  std::optional<Json> Value(int depth) {
    if (depth > kMaximumDepth) return std::nullopt;
    Space();
    if (position_ >= input_.size()) return std::nullopt;
    Json value;
    const char c = input_[position_];
    if (c == '{') return Object(depth);
    if (c == '[') return Array(depth);
    if (c == '"') {
      std::optional<std::string> text = String();
      if (!text) return std::nullopt;
      value.type = Json::Type::kString;
      value.text = std::move(*text);
      return value;
    }
    if (Literal("true")) {
      value.type = Json::Type::kBool;
      value.boolean = true;
      return value;
    }
    if (Literal("false")) {
      value.type = Json::Type::kBool;
      return value;
    }
    if (Literal("null")) return value;
    return Number();
  }

  std::optional<Json> Object(int depth) {
    Json value;
    value.type = Json::Type::kObject;
    ++position_;
    Space();
    if (position_ < input_.size() && input_[position_] == '}') {
      ++position_;
      return value;
    }
    while (true) {
      Space();
      if (position_ >= input_.size() || input_[position_] != '"') return std::nullopt;
      std::optional<std::string> key = String();
      if (!key || value.Find(*key) != nullptr) return std::nullopt;
      Space();
      if (position_ >= input_.size() || input_[position_++] != ':') return std::nullopt;
      std::optional<Json> member = Value(depth + 1);
      if (!member) return std::nullopt;
      value.object.emplace_back(std::move(*key), std::move(*member));
      Space();
      if (position_ >= input_.size()) return std::nullopt;
      const char next = input_[position_++];
      if (next == '}') return value;
      if (next != ',') return std::nullopt;
    }
  }

  std::optional<Json> Array(int depth) {
    Json value;
    value.type = Json::Type::kArray;
    ++position_;
    Space();
    if (position_ < input_.size() && input_[position_] == ']') {
      ++position_;
      return value;
    }
    while (true) {
      std::optional<Json> element = Value(depth + 1);
      if (!element) return std::nullopt;
      value.array.push_back(std::move(*element));
      Space();
      if (position_ >= input_.size()) return std::nullopt;
      const char next = input_[position_++];
      if (next == ']') return value;
      if (next != ',') return std::nullopt;
    }
  }

  std::optional<Json> Number() {
    const size_t start = position_;
    auto digits = [&] {
      const size_t from = position_;
      while (position_ < input_.size() && input_[position_] >= '0' && input_[position_] <= '9') {
        ++position_;
      }
      return position_ - from;
    };
    if (position_ < input_.size() && input_[position_] == '-') ++position_;
    if (position_ < input_.size() && input_[position_] == '0') {
      ++position_;
    } else if (digits() == 0) {
      return std::nullopt;
    }
    if (position_ < input_.size() && input_[position_] == '.') {
      ++position_;
      if (digits() == 0) return std::nullopt;
    }
    if (position_ < input_.size() && (input_[position_] == 'e' || input_[position_] == 'E')) {
      ++position_;
      if (position_ < input_.size() && (input_[position_] == '+' || input_[position_] == '-')) {
        ++position_;
      }
      if (digits() == 0) return std::nullopt;
    }
    Json value;
    value.type = Json::Type::kNumber;
    value.text = input_.substr(start, position_ - start);
    return value;
  }

  std::optional<uint32_t> Hex4() {
    if (position_ + 4 > input_.size()) return std::nullopt;
    uint32_t value = 0;
    for (int i = 0; i < 4; ++i) {
      const char c = input_[position_++];
      value <<= 4;
      if (c >= '0' && c <= '9') {
        value |= static_cast<uint32_t>(c - '0');
      } else if (c >= 'a' && c <= 'f') {
        value |= static_cast<uint32_t>(c - 'a' + 10);
      } else if (c >= 'A' && c <= 'F') {
        value |= static_cast<uint32_t>(c - 'A' + 10);
      } else {
        return std::nullopt;
      }
    }
    return value;
  }

  static void Append(std::string& out, uint32_t code) {
    if (code < 0x80) {
      out.push_back(static_cast<char>(code));
    } else if (code < 0x800) {
      out.push_back(static_cast<char>(0xc0 | (code >> 6)));
      out.push_back(static_cast<char>(0x80 | (code & 0x3f)));
    } else if (code < 0x10000) {
      out.push_back(static_cast<char>(0xe0 | (code >> 12)));
      out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3f)));
      out.push_back(static_cast<char>(0x80 | (code & 0x3f)));
    } else {
      out.push_back(static_cast<char>(0xf0 | (code >> 18)));
      out.push_back(static_cast<char>(0x80 | ((code >> 12) & 0x3f)));
      out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3f)));
      out.push_back(static_cast<char>(0x80 | (code & 0x3f)));
    }
  }

  // Raw bytes are copied as they are; callers that need valid UTF-8 or ASCII
  // check the decoded value themselves.
  std::optional<std::string> String() {
    ++position_;
    std::string out;
    while (position_ < input_.size()) {
      const unsigned char c = static_cast<unsigned char>(input_[position_++]);
      if (c == '"') return out;
      if (c < 0x20) return std::nullopt;
      if (c != '\\') {
        out.push_back(static_cast<char>(c));
        continue;
      }
      if (position_ >= input_.size()) return std::nullopt;
      const char escape = input_[position_++];
      switch (escape) {
        case '"': out.push_back('"'); break;
        case '\\': out.push_back('\\'); break;
        case '/': out.push_back('/'); break;
        case 'b': out.push_back('\b'); break;
        case 'f': out.push_back('\f'); break;
        case 'n': out.push_back('\n'); break;
        case 'r': out.push_back('\r'); break;
        case 't': out.push_back('\t'); break;
        case 'u': {
          std::optional<uint32_t> code = Hex4();
          if (!code) return std::nullopt;
          if (*code >= 0xdc00 && *code <= 0xdfff) return std::nullopt;
          if (*code >= 0xd800 && *code <= 0xdbff) {
            if (!Literal("\\u")) return std::nullopt;
            std::optional<uint32_t> low = Hex4();
            if (!low || *low < 0xdc00 || *low > 0xdfff) return std::nullopt;
            *code = 0x10000 + ((*code - 0xd800) << 10) + (*low - 0xdc00);
          }
          Append(out, *code);
          break;
        }
        default:
          return std::nullopt;
      }
    }
    return std::nullopt;
  }

  const std::string& input_;
  size_t position_ = 0;
};

}  // namespace

const Json* Json::Find(const std::string& key) const {
  for (const auto& member : object) {
    if (member.first == key) return &member.second;
  }
  return nullptr;
}

bool Json::IsInteger(long long value) const {
  return type == Type::kNumber && text == std::to_string(value);
}

std::optional<Json> ParseJson(const std::string& input) { return Parser(input).Document(); }

}  // namespace mila

// Checks the portable poke opener against the shared vectors in
// `protocol/test/fixtures/push_pokes.json`, the same file that tests
// `OverallsProtocol.PushPoke`, `mila_core`, the Swift and the Android
// openers. Usage: `mila_poke_opener_test PATH_TO_push_pokes.json`.
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>

#include "mila/json.h"
#include "mila/poke_opener.h"
#include "monocypher.h"

namespace {

int failures = 0;

void Expect(bool condition, const std::string& name) {
  if (!condition) {
    ++failures;
    std::printf("FAIL %s\n", name.c_str());
  } else {
    std::printf("ok   %s\n", name.c_str());
  }
}

mila::poke::PrivateKey Key(const std::string& hex) {
  mila::poke::PrivateKey key{};
  for (size_t i = 0; i < key.size() && i * 2 + 1 < hex.size(); ++i) {
    key[i] = static_cast<uint8_t>(std::stoi(hex.substr(i * 2, 2), nullptr, 16));
  }
  return key;
}

std::string Hex(const uint8_t* data, size_t size) {
  static const char digits[] = "0123456789abcdef";
  std::string out;
  for (size_t i = 0; i < size; ++i) {
    out.push_back(digits[data[i] >> 4]);
    out.push_back(digits[data[i] & 0xf]);
  }
  return out;
}

mila::poke::Refusal Reason(const std::string& name) {
  if (name == "encoding") return mila::poke::Refusal::kEncoding;
  if (name == "length") return mila::poke::Refusal::kLength;
  if (name == "version") return mila::poke::Refusal::kVersion;
  if (name == "plaintext") return mila::poke::Refusal::kPlaintext;
  return mila::poke::Refusal::kAuthentication;
}

const std::string& Field(const mila::Json& row, const char* name) {
  static const std::string empty;
  const mila::Json* value = row.Find(name);
  return value != nullptr && value->type == mila::Json::Type::kString ? value->text : empty;
}

void Vectors(const mila::Json& fixtures) {
  const mila::Json* valid = fixtures.Find("valid");
  const mila::Json* invalid = fixtures.Find("invalid");
  Expect(fixtures.Find("version") != nullptr && fixtures.Find("version")->IsInteger(1),
         "fixture version 1");
  Expect(valid != nullptr && !valid->array.empty(), "fixture has valid vectors");
  Expect(invalid != nullptr && !invalid->array.empty(), "fixture has invalid vectors");
  if (valid == nullptr || invalid == nullptr) return;

  for (const mila::Json& row : valid->array) {
    const std::string name = "valid: " + Field(row, "name");
    const mila::poke::PrivateKey key = Key(Field(row, "device_private"));
    uint8_t public_key[32];
    crypto_x25519_public_key(public_key, key.data());
    Expect(Hex(public_key, 32) == Field(row, "device_public"), name + " (device public key)");
    const mila::poke::Result result = mila::poke::Open(Field(row, "poke"), Field(row, "host"), key);
    const auto* opened = std::get_if<mila::poke::Poke>(&result);
    const std::optional<mila::Json> plaintext = mila::ParseJson(Field(row, "plaintext"));
    const mila::Json* route = plaintext ? plaintext->Find("route") : nullptr;
    Expect(opened != nullptr && route != nullptr && opened->route == route->text &&
               opened->kind == "needs_input",
           name);
  }

  for (const mila::Json& row : invalid->array) {
    const std::string name = "invalid: " + Field(row, "name");
    const mila::poke::Result result =
        mila::poke::Open(Field(row, "poke"), Field(row, "host"), Key(Field(row, "device_private")));
    const auto* refusal = std::get_if<mila::poke::Refusal>(&result);
    Expect(refusal != nullptr && *refusal == Reason(Field(row, "reason")), name);
  }
}

void Shapes() {
  using mila::poke::DecodeBase64Url;
  using mila::poke::DecodePlaintext;
  Expect(DecodeBase64Url("AQID").has_value() && DecodeBase64Url("AQID")->size() == 3,
         "base64url decodes");
  Expect(!DecodeBase64Url("AQI=").has_value(), "base64url refuses padding");
  Expect(!DecodeBase64Url("AQ+/").has_value(), "base64url refuses the standard alphabet");
  Expect(!DecodeBase64Url("AR").has_value(), "base64url refuses non-canonical bits");
  Expect(!DecodeBase64Url("A").has_value(), "base64url refuses a dangling character");

  Expect(DecodePlaintext(R"({"v":1,"kind":"needs_input","route":"/threads/a-1"})").has_value(),
         "plaintext accepts the exact shape");
  Expect(!DecodePlaintext(R"({"v":1.0,"kind":"needs_input","route":"/a"})"),
         "plaintext refuses a float version");
  Expect(!DecodePlaintext(R"({"v":true,"kind":"needs_input","route":"/a"})"),
         "plaintext refuses a boolean version");
  Expect(!DecodePlaintext(R"({"v":1,"kind":"other","route":"/a"})"),
         "plaintext refuses another kind");
  Expect(!DecodePlaintext(R"({"v":1,"kind":"needs_input","route":"/A?x"})"),
         "plaintext refuses a route outside the shape");
  Expect(!DecodePlaintext(R"({"v":1,"kind":"needs_input","route":"/a","x":0})"),
         "plaintext refuses extra members");
  Expect(!DecodePlaintext(R"({"v":1,"v":1,"kind":"needs_input"})"),
         "plaintext refuses duplicate members");
  Expect(!DecodePlaintext(R"({"v":1,"kind":"needs_input","route":"/a"} x)"),
         "plaintext refuses trailing input");

  const std::optional<std::string> wns = mila::poke::FromWnsPayload(
      R"({"overalls_v":"1","overalls_k":"needs_input","overalls_c":"AQID"})");
  Expect(wns.has_value() && *wns == "AQID", "WNS payload yields its poke");
  Expect(!mila::poke::FromWnsPayload(R"({"overalls_v":1,"overalls_k":"needs_input","overalls_c":"x"})"),
         "WNS payload refuses a numeric version");
  Expect(!mila::poke::FromWnsPayload("not json"), "WNS payload refuses other bodies");
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::printf("usage: mila_poke_opener_test push_pokes.json\n");
    return 2;
  }
  std::ifstream file(argv[1], std::ios::binary);
  std::stringstream contents;
  contents << file.rdbuf();
  const std::optional<mila::Json> fixtures = mila::ParseJson(contents.str());
  Expect(fixtures.has_value() && fixtures->type == mila::Json::Type::kObject, "fixtures parse");
  if (fixtures) Vectors(*fixtures);
  Shapes();
  std::printf("%d failure(s)\n", failures);
  return failures == 0 ? 0 : 1;
}

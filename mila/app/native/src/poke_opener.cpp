#include "mila/poke_opener.h"

#include <cstring>

#include "mila/hkdf.h"
#include "mila/json.h"
#include "monocypher.h"

namespace mila {
namespace poke {
namespace {

constexpr char kLabel[] = "overalls-mila-poke-v1";

int Sextet(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '-') return 62;
  if (c == '_') return 63;
  return -1;
}

}  // namespace

std::optional<std::vector<uint8_t>> DecodeBase64Url(const std::string& text) {
  if (text.size() % 4 == 1) return std::nullopt;
  std::vector<uint8_t> out;
  out.reserve(text.size() * 3 / 4);
  uint32_t buffer = 0;
  int bits = 0;
  for (const char c : text) {
    const int value = Sextet(c);
    if (value < 0) return std::nullopt;
    buffer = (buffer << 6) | static_cast<uint32_t>(value);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back(static_cast<uint8_t>(buffer >> bits));
      buffer &= (1u << bits) - 1;
    }
  }
  // Canonical only: the unused low bits of the last character are zero.
  if (buffer != 0) return std::nullopt;
  return out;
}

bool ValidRoute(const std::string& route) {
  if (route.empty() || route[0] != '/' || route.size() > 256) return false;
  for (const char c : route) {
    const bool allowed = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '/' || c == '-';
    if (!allowed) return false;
  }
  return true;
}

std::optional<Poke> DecodePlaintext(const std::string& plaintext) {
  if (plaintext.size() > kMaximumPlaintext) return std::nullopt;
  const std::optional<Json> value = ParseJson(plaintext);
  if (!value || value->type != Json::Type::kObject || value->object.size() != 3) {
    return std::nullopt;
  }
  const Json* version = value->Find("v");
  const Json* kind = value->Find("kind");
  const Json* route = value->Find("route");
  if (version == nullptr || !version->IsInteger(1)) return std::nullopt;
  if (kind == nullptr || kind->type != Json::Type::kString || kind->text != "needs_input") {
    return std::nullopt;
  }
  if (route == nullptr || route->type != Json::Type::kString || !ValidRoute(route->text)) {
    return std::nullopt;
  }
  return Poke{kind->text, route->text};
}

Result Open(const std::string& poke, const std::string& host, const PrivateKey& private_key) {
  if (poke.size() > (kMaximumBytes * 4 + 2) / 3) return Refusal::kLength;
  std::optional<std::vector<uint8_t>> decoded = DecodeBase64Url(poke);
  if (!decoded) return Refusal::kEncoding;
  const std::vector<uint8_t>& b = *decoded;
  if (b.size() < kMinimumBytes || b.size() > kMaximumBytes) return Refusal::kLength;
  if (b[0] != 1) return Refusal::kVersion;
  if (host.empty()) return Refusal::kAuthentication;
  for (const char c : host) {
    if (static_cast<unsigned char>(c) > 0x7f) return Refusal::kAuthentication;
  }

  const uint8_t* ephemeral = b.data() + 1;
  const uint8_t* nonce = b.data() + 33;
  const uint8_t* ciphertext = b.data() + 45;
  const size_t text_size = b.size() - kMinimumBytes;
  const uint8_t* tag = ciphertext + text_size;

  uint8_t device_public[32];
  crypto_x25519_public_key(device_public, private_key.data());
  Bytes shared(32);
  crypto_x25519(shared.data(), private_key.data(), ephemeral);
  // An all-zero (low-order) result is never authentic.
  uint8_t accumulated = 0;
  for (const uint8_t byte : shared) accumulated |= byte;
  if (accumulated == 0) return Refusal::kAuthentication;

  Bytes salt(ephemeral, ephemeral + 32);
  salt.insert(salt.end(), device_public, device_public + 32);
  const Bytes info(kLabel, kLabel + sizeof(kLabel) - 1);
  Bytes key = HkdfSha256(shared, salt, info, 32);
  crypto_wipe(shared.data(), shared.size());

  Bytes aad = info;
  aad.push_back(0);
  aad.insert(aad.end(), host.begin(), host.end());

  crypto_aead_ctx context;
  crypto_aead_init_ietf(&context, key.data(), nonce);
  std::string plaintext(text_size, '\0');
  const int status = crypto_aead_read(&context, reinterpret_cast<uint8_t*>(plaintext.data()), tag,
                                      aad.data(), aad.size(), ciphertext, text_size);
  crypto_wipe(&context, sizeof(context));
  crypto_wipe(key.data(), key.size());
  if (status != 0) return Refusal::kAuthentication;
  std::optional<Poke> opened = DecodePlaintext(plaintext);
  crypto_wipe(plaintext.data(), plaintext.size());
  if (!opened) return Refusal::kPlaintext;
  return *opened;
}

std::optional<std::string> FromWnsPayload(const std::string& body) {
  if (body.size() > 4096) return std::nullopt;
  const std::optional<Json> value = ParseJson(body);
  if (!value || value->type != Json::Type::kObject || value->object.size() != 3) {
    return std::nullopt;
  }
  const Json* version = value->Find("overalls_v");
  const Json* kind = value->Find("overalls_k");
  const Json* poke = value->Find("overalls_c");
  if (version == nullptr || version->type != Json::Type::kString || version->text != "1") {
    return std::nullopt;
  }
  if (kind == nullptr || kind->type != Json::Type::kString || kind->text != "needs_input") {
    return std::nullopt;
  }
  if (poke == nullptr || poke->type != Json::Type::kString) return std::nullopt;
  return poke->text;
}

}  // namespace poke
}  // namespace mila

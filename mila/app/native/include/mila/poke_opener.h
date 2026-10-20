#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <variant>
#include <vector>

namespace mila {

// @cc [owner:ghuntley,label:security;protocol] mila-native-poke-open-v1
// The native opener MUST refuse, without throwing, anything but an authentic
// v1 poke sealed to a stored device key for that key's deployment host, with
// exactly `{v: 1, kind: "needs_input", route}`. Refusals MUST NOT carry or log
// poke bytes, keys or plaintext.

// Opens end-to-end encrypted pokes, format v1 (ADR-0224, ADR-0225), exactly
// as `mila_core`'s `openPoke`, `darwin/Shared/PokeOpener.swift` and
// `protocol/test/fixtures/push_pokes.json`:
//
// - `0x01 || ephemeral_public(32) || nonce(12) || ciphertext || tag(16)`,
//   base64url without padding;
// - key = HKDF-SHA256(X25519(device, ephemeral), salt = ephemeral_public ||
//   device_public, info = "overalls-mila-poke-v1", 32 bytes);
// - ChaCha20-Poly1305 (RFC 8439) with AAD "overalls-mila-poke-v1" || 0x00 ||
//   host;
// - plaintext exactly {v: 1, kind: "needs_input", route: "/..."}.
//
// Portable C++17 over Monocypher, so the Windows runner uses it and CTest
// checks it on every host.
namespace poke {

constexpr size_t kMinimumBytes = 1 + 32 + 12 + 16;
constexpr size_t kMaximumPlaintext = 512;
constexpr size_t kMaximumBytes = kMinimumBytes + kMaximumPlaintext;

enum class Refusal { kEncoding, kLength, kVersion, kAuthentication, kPlaintext };

struct Poke {
  std::string kind;
  std::string route;
};

using PrivateKey = std::array<uint8_t, 32>;
using Result = std::variant<Poke, Refusal>;

// Strict unpadded base64url: no padding, no other alphabet, canonical only.
std::optional<std::vector<uint8_t>> DecodeBase64Url(const std::string& text);

Result Open(const std::string& poke, const std::string& host,
            const PrivateKey& private_key);

std::optional<Poke> DecodePlaintext(const std::string& plaintext);

// A coarse shape check; the Dart router re-validates the closed table.
bool ValidRoute(const std::string& route);

// The poke inside a WNS raw notification body from Susan
// (`{"overalls_v": "1", "overalls_k": "needs_input", "overalls_c": POKE}`),
// or nothing for any other shape.
std::optional<std::string> FromWnsPayload(const std::string& body);

}  // namespace poke
}  // namespace mila

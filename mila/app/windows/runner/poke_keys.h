#ifndef RUNNER_POKE_KEYS_H_
#define RUNNER_POKE_KEYS_H_

#include <array>
#include <optional>
#include <string>
#include <utility>
#include <vector>

// @cc [owner:ghuntley,label:security] mila-poke-keys-stay-native
// Poke private keys MUST stay sealed with DPAPI for the current user, in
// owner-only files under the data directory. Only the 32-byte public key MAY
// cross the platform channel; private keys MUST NOT be logged or exported.
//
// X25519 keys, which a TPM cannot hold, one per deployment host: file
// `%LOCALAPPDATA%\dev.overalls.mila\poke\HOST.key`, contents
// `CryptProtectData(private key)` with the host as extra entropy, so a file
// copied to another host name or user does not open.
namespace poke_keys {

using PrivateKey = std::array<unsigned char, 32>;

// The public key for [host], creating the key on first use.
std::optional<std::array<unsigned char, 32>> PublicKey(const std::string& host);

void Delete(const std::string& host);

// Every stored key with its host, for the poke opener.
std::vector<std::pair<std::string, PrivateKey>> All();

}  // namespace poke_keys

#endif  // RUNNER_POKE_KEYS_H_

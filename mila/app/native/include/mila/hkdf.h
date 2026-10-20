#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace mila {

using Bytes = std::vector<uint8_t>;
using Sha256Digest = std::array<uint8_t, 32>;

// SHA-256 (FIPS 180-4), HMAC-SHA256 (RFC 2104) and HKDF-SHA256 (RFC 5869)
// for the poke opener, which needs nothing else from a hash library. Inputs
// are key material; nothing here logs or keeps a copy.
Sha256Digest Sha256(const uint8_t* data, size_t size);
Sha256Digest HmacSha256(const uint8_t* key, size_t key_size,
                        const uint8_t* data, size_t size);
// At most 255 * 32 bytes; [length] is not checked beyond that bound.
Bytes HkdfSha256(const Bytes& ikm, const Bytes& salt, const Bytes& info,
                 size_t length);

}  // namespace mila

#include "mila/hkdf.h"

#include <cstring>

namespace mila {
namespace {

constexpr uint32_t kRound[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

uint32_t Rotate(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

class Sha256State {
 public:
  void Update(const uint8_t* data, size_t size) {
    for (size_t i = 0; i < size; ++i) {
      block_[used_++] = data[i];
      if (used_ == 64) {
        Compress();
        used_ = 0;
      }
    }
    bits_ += static_cast<uint64_t>(size) * 8;
  }

  Sha256Digest Finish() {
    const uint64_t bits = bits_;
    const uint8_t one = 0x80;
    Update(&one, 1);
    const uint8_t zero = 0;
    while (used_ != 56) Update(&zero, 1);
    uint8_t length[8];
    for (int i = 0; i < 8; ++i) length[i] = static_cast<uint8_t>(bits >> (56 - 8 * i));
    Update(length, 8);
    Sha256Digest out;
    for (int i = 0; i < 8; ++i) {
      for (int j = 0; j < 4; ++j) out[i * 4 + j] = static_cast<uint8_t>(h_[i] >> (24 - 8 * j));
    }
    return out;
  }

 private:
  void Compress() {
    uint32_t w[64];
    for (int i = 0; i < 16; ++i) {
      w[i] = (uint32_t{block_[i * 4]} << 24) | (uint32_t{block_[i * 4 + 1]} << 16) |
             (uint32_t{block_[i * 4 + 2]} << 8) | uint32_t{block_[i * 4 + 3]};
    }
    for (int i = 16; i < 64; ++i) {
      const uint32_t s0 = Rotate(w[i - 15], 7) ^ Rotate(w[i - 15], 18) ^ (w[i - 15] >> 3);
      const uint32_t s1 = Rotate(w[i - 2], 17) ^ Rotate(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h_[0], b = h_[1], c = h_[2], d = h_[3];
    uint32_t e = h_[4], f = h_[5], g = h_[6], h = h_[7];
    for (int i = 0; i < 64; ++i) {
      const uint32_t s1 = Rotate(e, 6) ^ Rotate(e, 11) ^ Rotate(e, 25);
      const uint32_t choose = (e & f) ^ (~e & g);
      const uint32_t t1 = h + s1 + choose + kRound[i] + w[i];
      const uint32_t s0 = Rotate(a, 2) ^ Rotate(a, 13) ^ Rotate(a, 22);
      const uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
      const uint32_t t2 = s0 + majority;
      h = g;
      g = f;
      f = e;
      e = d + t1;
      d = c;
      c = b;
      b = a;
      a = t1 + t2;
    }
    h_[0] += a;
    h_[1] += b;
    h_[2] += c;
    h_[3] += d;
    h_[4] += e;
    h_[5] += f;
    h_[6] += g;
    h_[7] += h;
  }

  uint32_t h_[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  uint8_t block_[64] = {};
  size_t used_ = 0;
  uint64_t bits_ = 0;
};

}  // namespace

Sha256Digest Sha256(const uint8_t* data, size_t size) {
  Sha256State state;
  state.Update(data, size);
  return state.Finish();
}

Sha256Digest HmacSha256(const uint8_t* key, size_t key_size,
                        const uint8_t* data, size_t size) {
  uint8_t block[64] = {};
  if (key_size > 64) {
    const Sha256Digest hashed = Sha256(key, key_size);
    std::memcpy(block, hashed.data(), hashed.size());
  } else if (key_size > 0) {
    std::memcpy(block, key, key_size);
  }
  uint8_t pad[64];
  for (int i = 0; i < 64; ++i) pad[i] = block[i] ^ 0x36;
  Sha256State inner;
  inner.Update(pad, 64);
  inner.Update(data, size);
  const Sha256Digest inner_digest = inner.Finish();
  for (int i = 0; i < 64; ++i) pad[i] = block[i] ^ 0x5c;
  Sha256State outer;
  outer.Update(pad, 64);
  outer.Update(inner_digest.data(), inner_digest.size());
  return outer.Finish();
}

Bytes HkdfSha256(const Bytes& ikm, const Bytes& salt, const Bytes& info,
                 size_t length) {
  const Sha256Digest prk = HmacSha256(salt.data(), salt.size(), ikm.data(), ikm.size());
  Bytes out;
  Bytes previous;
  for (uint8_t counter = 1; out.size() < length; ++counter) {
    Bytes input = previous;
    input.insert(input.end(), info.begin(), info.end());
    input.push_back(counter);
    const Sha256Digest block = HmacSha256(prk.data(), prk.size(), input.data(), input.size());
    previous.assign(block.begin(), block.end());
    out.insert(out.end(), block.begin(), block.end());
  }
  out.resize(length);
  return out;
}

}  // namespace mila

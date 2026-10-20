#include "poke_keys.h"

// clang-format off
#include <windows.h>
#include <bcrypt.h>
#include <dpapi.h>
// clang-format on

#include <algorithm>

#include "mila_text.h"
#include "monocypher.h"
#include "owner_only.h"

namespace poke_keys {
namespace {

constexpr char kEntropyLabel[] = "dev.overalls.mila.poke";

std::optional<std::wstring> Directory() {
  const std::optional<std::wstring> data = owner_only::DataDirectory();
  if (!data) return std::nullopt;
  const std::wstring path = *data + L"\\poke";
  if (!owner_only::EnsureDirectory(path)) return std::nullopt;
  return path;
}

std::optional<std::wstring> PathFor(const std::string& host) {
  if (!mila_text::ValidHost(host)) return std::nullopt;
  const std::optional<std::wstring> directory = Directory();
  if (!directory) return std::nullopt;
  return *directory + L"\\" + mila_text::Wide(host) + L".key";
}

std::vector<unsigned char> Entropy(const std::string& host) {
  std::vector<unsigned char> entropy(kEntropyLabel, kEntropyLabel + sizeof(kEntropyLabel));
  entropy.insert(entropy.end(), host.begin(), host.end());
  return entropy;
}

std::optional<std::vector<unsigned char>> Seal(const std::string& host, const PrivateKey& key) {
  std::vector<unsigned char> entropy = Entropy(host);
  DATA_BLOB in{static_cast<DWORD>(key.size()), const_cast<BYTE*>(key.data())};
  DATA_BLOB extra{static_cast<DWORD>(entropy.size()), entropy.data()};
  DATA_BLOB out{};
  if (!::CryptProtectData(&in, nullptr, &extra, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN,
                          &out)) {
    return std::nullopt;
  }
  std::vector<unsigned char> sealed(out.pbData, out.pbData + out.cbData);
  ::LocalFree(out.pbData);
  return sealed;
}

std::optional<PrivateKey> Unseal(const std::string& host, std::vector<unsigned char> sealed) {
  std::vector<unsigned char> entropy = Entropy(host);
  DATA_BLOB in{static_cast<DWORD>(sealed.size()), sealed.data()};
  DATA_BLOB extra{static_cast<DWORD>(entropy.size()), entropy.data()};
  DATA_BLOB out{};
  if (!::CryptUnprotectData(&in, nullptr, &extra, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN,
                            &out)) {
    return std::nullopt;
  }
  std::optional<PrivateKey> key;
  if (out.cbData == 32) {
    key = PrivateKey{};
    std::copy(out.pbData, out.pbData + 32, key->begin());
  }
  ::SecureZeroMemory(out.pbData, out.cbData);
  ::LocalFree(out.pbData);
  return key;
}

std::optional<PrivateKey> Load(const std::string& host) {
  const std::optional<std::wstring> path = PathFor(host);
  if (!path) return std::nullopt;
  std::optional<std::vector<unsigned char>> sealed = owner_only::ReadFile(*path, 4096);
  if (!sealed) return std::nullopt;
  return Unseal(host, std::move(*sealed));
}

}  // namespace

std::optional<std::array<unsigned char, 32>> PublicKey(const std::string& host) {
  std::optional<PrivateKey> stored = Load(host);
  std::array<unsigned char, 32> public_key{};
  if (stored) {
    crypto_x25519_public_key(public_key.data(), stored->data());
    crypto_wipe(stored->data(), stored->size());
    return public_key;
  }
  const std::optional<std::wstring> path = PathFor(host);
  if (!path) return std::nullopt;
  PrivateKey key{};
  if (!BCRYPT_SUCCESS(::BCryptGenRandom(nullptr, key.data(), static_cast<ULONG>(key.size()),
                                        BCRYPT_USE_SYSTEM_PREFERRED_RNG))) {
    return std::nullopt;
  }
  const std::optional<std::vector<unsigned char>> sealed = Seal(host, key);
  crypto_x25519_public_key(public_key.data(), key.data());
  crypto_wipe(key.data(), key.size());
  if (!sealed || !owner_only::WriteFile(*path, *sealed)) return std::nullopt;
  return public_key;
}

void Delete(const std::string& host) {
  const std::optional<std::wstring> path = PathFor(host);
  if (path) ::DeleteFileW(path->c_str());
}

std::vector<std::pair<std::string, PrivateKey>> All() {
  std::vector<std::pair<std::string, PrivateKey>> keys;
  const std::optional<std::wstring> directory = Directory();
  if (!directory) return keys;
  WIN32_FIND_DATAW entry{};
  HANDLE find = ::FindFirstFileW((*directory + L"\\*.key").c_str(), &entry);
  if (find == INVALID_HANDLE_VALUE) return keys;
  do {
    if (entry.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) {
      continue;
    }
    std::wstring name(entry.cFileName);
    // The pattern can match short names; require the exact suffix.
    if (name.size() <= 4 || name.compare(name.size() - 4, 4, L".key") != 0) continue;
    name.resize(name.size() - 4);
    const std::string host = mila_text::Utf8(name);
    if (!mila_text::ValidHost(host)) continue;
    std::optional<PrivateKey> key = Load(host);
    if (key) keys.emplace_back(host, *key);
  } while (::FindNextFileW(find, &entry));
  ::FindClose(find);
  return keys;
}

}  // namespace poke_keys

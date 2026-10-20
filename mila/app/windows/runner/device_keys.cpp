#include "device_keys.h"

// clang-format off
#include <windows.h>
#include <bcrypt.h>
#include <ncrypt.h>
// clang-format on

#include "mila_text.h"

namespace device_keys {
namespace {

struct Provider {
  explicit Provider(LPCWSTR name) {
    if (FAILED(::NCryptOpenStorageProvider(&handle, name, 0))) handle = 0;
  }
  ~Provider() {
    if (handle) ::NCryptFreeObject(handle);
  }
  Provider(const Provider&) = delete;
  Provider& operator=(const Provider&) = delete;
  NCRYPT_PROV_HANDLE handle = 0;
};

struct Key {
  Key() = default;
  ~Key() {
    if (handle) ::NCryptFreeObject(handle);
  }
  Key(const Key&) = delete;
  Key& operator=(const Key&) = delete;
  NCRYPT_KEY_HANDLE handle = 0;
  Custody custody = Custody::kSoftware;
};

std::wstring Name(const std::string& host) {
  return L"dev.overalls.mila.device." + mila_text::Wide(host);
}

LPCWSTR ProviderName(Custody custody) {
  return custody == Custody::kPlatform ? MS_PLATFORM_CRYPTO_PROVIDER : MS_KEY_STORAGE_PROVIDER;
}

bool Open(Custody custody, const std::wstring& name, Key& key) {
  Provider provider(ProviderName(custody));
  if (!provider.handle) return false;
  if (FAILED(::NCryptOpenKey(provider.handle, &key.handle, name.c_str(), 0, 0))) {
    key.handle = 0;
    return false;
  }
  key.custody = custody;
  return true;
}

bool Create(Custody custody, const std::wstring& name, Key& key) {
  Provider provider(ProviderName(custody));
  if (!provider.handle) return false;
  if (FAILED(::NCryptCreatePersistedKey(provider.handle, &key.handle, BCRYPT_ECDSA_P256_ALGORITHM,
                                        name.c_str(), 0, 0))) {
    key.handle = 0;
    return false;
  }
  // Persisted keys are non-exportable by default; say so explicitly for the
  // software provider, where the policy is a property.
  DWORD policy = 0;
  ::NCryptSetProperty(key.handle, NCRYPT_EXPORT_POLICY_PROPERTY,
                      reinterpret_cast<PBYTE>(&policy), sizeof(policy), NCRYPT_PERSIST_FLAG);
  if (FAILED(::NCryptFinalizeKey(key.handle, 0))) {
    ::NCryptDeleteKey(key.handle, 0);  // Frees the handle.
    key.handle = 0;
    return false;
  }
  key.custody = custody;
  return true;
}

// The existing key from whichever provider holds it, else a new one in the
// TPM, else (no TPM, or a TPM that refuses) a new software key.
bool Load(const std::string& host, bool create, Key& key) {
  if (!mila_text::ValidHost(host)) return false;
  const std::wstring name = Name(host);
  if (Open(Custody::kPlatform, name, key) || Open(Custody::kSoftware, name, key)) return true;
  if (!create) return false;
  return Create(Custody::kPlatform, name, key) || Create(Custody::kSoftware, name, key);
}

void AppendInteger(std::vector<unsigned char>& out, const unsigned char* value, size_t size) {
  size_t start = 0;
  while (start + 1 < size && value[start] == 0) ++start;
  const bool pad = (value[start] & 0x80) != 0;
  out.push_back(0x02);
  out.push_back(static_cast<unsigned char>(size - start + (pad ? 1 : 0)));
  if (pad) out.push_back(0);
  out.insert(out.end(), value + start, value + size);
}

}  // namespace

std::vector<unsigned char> DerSignature(const unsigned char* raw, size_t size) {
  std::vector<unsigned char> body;
  AppendInteger(body, raw, size / 2);
  AppendInteger(body, raw + size / 2, size / 2);
  std::vector<unsigned char> out{0x30, static_cast<unsigned char>(body.size())};
  out.insert(out.end(), body.begin(), body.end());
  return out;
}

std::optional<std::vector<unsigned char>> PublicPoint(const std::string& host) {
  Key key;
  if (!Load(host, true, key)) return std::nullopt;
  DWORD size = 0;
  if (FAILED(::NCryptExportKey(key.handle, 0, BCRYPT_ECCPUBLIC_BLOB, nullptr, nullptr, 0, &size,
                               0))) {
    return std::nullopt;
  }
  std::vector<unsigned char> blob(size);
  if (FAILED(::NCryptExportKey(key.handle, 0, BCRYPT_ECCPUBLIC_BLOB, nullptr, blob.data(), size,
                               &size, 0)) ||
      size != sizeof(BCRYPT_ECCKEY_BLOB) + 64) {
    return std::nullopt;
  }
  const auto* header = reinterpret_cast<const BCRYPT_ECCKEY_BLOB*>(blob.data());
  if (header->dwMagic != BCRYPT_ECDSA_PUBLIC_P256_MAGIC || header->cbKey != 32) return std::nullopt;
  std::vector<unsigned char> point{0x04};
  point.insert(point.end(), blob.begin() + sizeof(BCRYPT_ECCKEY_BLOB), blob.end());
  return point;
}

std::optional<std::vector<unsigned char>> Sign(const std::string& host,
                                               const std::vector<unsigned char>& data) {
  Key key;
  // As on darwin, signing creates the key if Dart has not asked for it yet.
  if (!Load(host, true, key)) return std::nullopt;
  unsigned char digest[32];
  if (!BCRYPT_SUCCESS(::BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0,
                                   const_cast<PUCHAR>(data.data()),
                                   static_cast<ULONG>(data.size()), digest, sizeof(digest)))) {
    return std::nullopt;
  }
  unsigned char raw[64];
  DWORD size = 0;
  if (FAILED(::NCryptSignHash(key.handle, nullptr, digest, sizeof(digest), raw, sizeof(raw), &size,
                              0)) ||
      size != sizeof(raw)) {
    return std::nullopt;
  }
  return DerSignature(raw, sizeof(raw));
}

std::optional<Custody> CustodyOf(const std::string& host) {
  Key key;
  if (!Load(host, false, key)) return std::nullopt;
  return key.custody;
}

}  // namespace device_keys

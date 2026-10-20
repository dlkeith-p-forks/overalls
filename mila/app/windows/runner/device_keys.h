#ifndef RUNNER_DEVICE_KEYS_H_
#define RUNNER_DEVICE_KEYS_H_

#include <optional>
#include <string>
#include <vector>

// @cc [owner:ghuntley,label:security] mila-windows-device-key-custody
// Each deployment host MUST have one non-exportable CNG ECDSA P-256 key,
// created in the TPM (Microsoft Platform Crypto Provider) when one is
// usable and otherwise in the Microsoft Software Key Storage Provider, with
// no refusal. An existing key MUST be reopened from the provider that holds
// it. Only the public point and DER signatures leave this module; private
// keys, handles and provider errors MUST NOT be logged.
namespace device_keys {

enum class Custody { kPlatform, kSoftware };

// The uncompressed point `04 || X || Y`, 65 bytes, as
// `DeviceKeys.publicPoint` on darwin; the key is created on first use.
std::optional<std::vector<unsigned char>> PublicPoint(const std::string& host);

// A DER `SEQUENCE { INTEGER r, INTEGER s }` ECDSA signature over SHA-256 of
// [data], as `.ecdsaSignatureMessageX962SHA256` produces on darwin.
std::optional<std::vector<unsigned char>> Sign(const std::string& host,
                                               const std::vector<unsigned char>& data);

// Which provider holds [host]'s key, if one exists.
std::optional<Custody> CustodyOf(const std::string& host);

// DER encoding of a raw 64-byte `r || s` signature; exposed for tests.
std::vector<unsigned char> DerSignature(const unsigned char* raw, size_t size);

}  // namespace device_keys

#endif  // RUNNER_DEVICE_KEYS_H_

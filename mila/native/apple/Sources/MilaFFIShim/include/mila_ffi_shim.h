#ifndef MILA_FFI_SHIM_H
#define MILA_FFI_SHIM_H
#include <stddef.h>
#include <stdint.h>
struct mila_ffi_abi_version { uint32_t major; uint32_t minor; };
struct mila_route_output { uint8_t *bytes; size_t capacity; size_t *written; };
struct mila_snapshot_summary { uint32_t machine_count; uint64_t saved_at; };
int32_t mila_ffi_get_version(struct mila_ffi_abi_version *version);
int32_t mila_route_format(const char *input, struct mila_route_output output);
int32_t mila_snapshot_validate(const uint8_t *bytes, size_t length, const char *host,
                               uint16_t port, uint8_t has_port,
                               struct mila_snapshot_summary *summary);
#endif

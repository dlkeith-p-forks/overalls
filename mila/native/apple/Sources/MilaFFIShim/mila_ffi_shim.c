#include <stdint.h>
#include <stddef.h>

struct mila_ffi_abi_version { uint32_t major; uint32_t minor; };
struct mila_route_output { uint8_t *bytes; size_t capacity; size_t *written; };
struct mila_snapshot_summary { uint32_t machine_count; uint64_t saved_at; };

/* Weak fallbacks keep the Swift package linkable for development and tests.
 * The host application links mila-ffi's strong symbols when configured. */
__attribute__((weak)) int32_t mila_ffi_get_version(struct mila_ffi_abi_version *version) {
    if (version) { version->major = 0; version->minor = 0; }
    return -1;
}

__attribute__((weak)) int32_t mila_route_format(const char *input, struct mila_route_output output) {
    (void)input;
    if (output.written) *output.written = 0;
    return -1;
}

__attribute__((weak)) int32_t mila_snapshot_validate(const uint8_t *bytes, size_t length,
                                                       const char *host, uint16_t port,
                                                       uint8_t has_port,
                                                       struct mila_snapshot_summary *summary) {
    (void)bytes; (void)length; (void)host; (void)port; (void)has_port;
    if (summary) { summary->machine_count = 0; summary->saved_at = 0; }
    return -1;
}

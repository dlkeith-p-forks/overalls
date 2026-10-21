#include <stdint.h>
#include <stddef.h>

struct mila_ffi_abi_version { uint32_t major; uint32_t minor; };
struct mila_route_output { uint8_t *bytes; size_t capacity; size_t *written; };

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

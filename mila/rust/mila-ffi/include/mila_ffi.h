#ifndef MILA_FFI_H
#define MILA_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum MilaFfiStatus {
  MILA_FFI_OK = 0,
  MILA_FFI_NULL_INPUT = -1,
  MILA_FFI_INVALID_ROUTE = -2,
  MILA_FFI_OUTPUT_TOO_SMALL = -3,
  MILA_FFI_INVALID_REQUEST = -4
} MilaFfiStatus;

typedef struct MilaFfiAbiVersion {
  uint32_t major;
  uint32_t minor;
} MilaFfiAbiVersion;

typedef struct MilaRouteOutput {
  uint8_t *bytes;
  size_t capacity;
  size_t *written;
} MilaRouteOutput;

typedef struct MilaSnapshotSummary {
  uint32_t machine_count;
  uint64_t saved_at;
} MilaSnapshotSummary;

/* Returns the ABI major version. */
uint32_t mila_ffi_version(void);
/* Writes the complete ABI version, returning MILA_FFI_NULL_INPUT when absent. */
MilaFfiStatus mila_ffi_get_version(MilaFfiAbiVersion *out_version);
/* Canonicalizes a bounded overalls:// route into caller-owned storage. */
MilaFfiStatus mila_route_format(const char *input, MilaRouteOutput output);
/* Validates a bounded trust document against its expected management host. */
MilaFfiStatus mila_trust_document_validate(const uint8_t *document, size_t length,
                                           const char *origin_host, uint64_t now);
/* Validates push registration metadata; token bytes are never returned. */
MilaFfiStatus mila_push_registration_validate(uint8_t provider, uint8_t environment,
                                              const char *token, const char *app_id,
                                              const char *deployment, const char *endpoint);
/* Validates bounded watch filter counts (maximum 64 combined). */
MilaFfiStatus mila_watch_validate_filters(uint16_t machine_count, uint16_t thread_count);
/* Validates an offline snapshot for a deployment and returns safe metadata. */
MilaFfiStatus mila_snapshot_validate(const uint8_t *bytes, size_t length,
                                     const char *host, uint16_t port,
                                     uint8_t has_port, MilaSnapshotSummary *out_summary);

#ifdef __cplusplus
}
#endif
#endif

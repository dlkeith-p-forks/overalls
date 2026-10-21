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

typedef struct MilaMachineActions { uint16_t bits; } MilaMachineActions;

typedef struct MilaSnapshotSummary {
  uint32_t machine_count;
  uint64_t saved_at;
} MilaSnapshotSummary;

MilaFfiStatus mila_session_command_format(const char *action, const char *machine_id, const char *request_id, MilaRouteOutput output);
MilaFfiStatus mila_snapshot_machine_actions(const uint8_t *bytes, size_t length, const char *host, uint16_t port, uint8_t has_port, uint32_t index, MilaMachineActions *out_actions);
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
/* Validates a bounded Susan push poke envelope; ciphertext is never returned. */
MilaFfiStatus mila_push_poke_validate(const uint8_t *envelope, size_t length, uint64_t now);
/* Validates bounded watch filter counts (maximum 64 combined). */
MilaFfiStatus mila_watch_validate_filters(uint16_t machine_count, uint16_t thread_count);
MilaFfiStatus mila_terminal_attach_validate(uint64_t from, uint16_t columns, uint16_t rows, uint8_t read_write);
/* Input bytes remain owned by the native host and never cross this ABI. */
MilaFfiStatus mila_terminal_input_validate(size_t length, uint8_t read_write);
MilaFfiStatus mila_terminal_resize_validate(uint16_t columns, uint16_t rows, uint8_t read_write);
/* Validates an offline snapshot for a deployment and returns safe metadata. */
MilaFfiStatus mila_snapshot_validate(const uint8_t *bytes, size_t length,
                                     const char *host, uint16_t port,
                                     uint8_t has_port, MilaSnapshotSummary *out_summary);

/* Blocking live sessions: invoke on a worker thread, never from a Tokio runtime.
 * A callback signs SHA256(message) with its non-exportable P256 deployment key,
 * writes 64 bytes r||s, and returns 0. It/context are borrowed only during connect.
 * public_key is an OpenSSH ecdsa-sha2-nistp256 string. Inputs are length-bounded,
 * not NUL terminated. Trust must already be pinned by the native deployment store.
 * Return codes: 0 success, -3 small buffer, -4 invalid, -10 stale handle,
 * -11 transport/refusal, -12 unloaded/incomplete, -13 busy, -14 internal failure.
 */
typedef int32_t (*MilaSessionSign)(uintptr_t context, const uint8_t *message,
                                  size_t length, uint8_t *signature64);
int32_t mila_session_connect(const uint8_t *trust, size_t trust_len,
    const uint8_t *host, size_t host_len, const uint8_t *public_key,
    size_t public_key_len, uint16_t port, uint32_t timeout_ms,
    MilaSessionSign signer, uintptr_t context, uint64_t *out_handle);
int32_t mila_session_read_machines(uint64_t handle, uint8_t more);
/* Copy operations never issue a command. Null output/zero capacity queries size.
 * JSON is UTF-8 without NUL termination; written receives the required length.
 * Listing is {machines:[validated snapshot rows],has_more:boolean}.
 */
int32_t mila_session_listing(uint64_t handle, uint8_t *output, size_t capacity,
    size_t *written);
int32_t mila_session_snapshot(uint64_t handle, uint64_t saved_at,
    uint8_t *output, size_t capacity, size_t *written);
int32_t mila_session_close(uint64_t handle);

#ifdef __cplusplus
}
#endif
#endif

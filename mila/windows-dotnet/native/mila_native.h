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

typedef enum MilaWatchEventKind {
  MILA_WATCH_UNKNOWN = 0,
  MILA_WATCHING = 1,
  MILA_HEARTBEAT = 2,
  MILA_MACHINE_CHANGED = 3,
  MILA_TERMINAL_SESSIONS_CHANGED = 4,
  MILA_THREAD_CHANGED = 5,
  MILA_RESYNC = 6,
  MILA_SESSION = 7
} MilaWatchEventKind;

typedef struct MilaFfiAbiVersion {
  uint32_t major;
  uint32_t minor;
} MilaFfiAbiVersion;

typedef struct MilaRouteOutput {
  uint8_t *bytes;
  size_t capacity;
  size_t *written;
} MilaRouteOutput;

/* Returns the ABI major version. */
uint32_t mila_ffi_version(void);
/* Writes the complete ABI version, returning MILA_FFI_NULL_INPUT when absent. */
MilaFfiStatus mila_ffi_get_version(MilaFfiAbiVersion *out_version);
/* Canonicalizes a bounded overalls:// route into caller-owned storage. */
MilaFfiStatus mila_route_format(const char *input, MilaRouteOutput output);
/* Validates PTY dimensions and read/write mode before opening a terminal. */
MilaFfiStatus mila_terminal_validate(uint16_t columns, uint16_t rows,
                                     uint8_t read_write);
typedef enum MilaThreadCommandKind { MILA_THREAD_UNKNOWN = 0, MILA_THREAD_LIST = 1, MILA_THREAD_SHOW = 2, MILA_THREAD_TURNS = 3, MILA_THREAD_PROMPT = 4, MILA_THREAD_ANSWER = 5, MILA_THREAD_PLAN_APPROVE = 6, MILA_THREAD_PLAN_REVISE = 7, MILA_THREAD_MODE = 8, MILA_THREAD_READ = 9 } MilaThreadCommandKind;
MilaFfiStatus mila_thread_command_kind(const char *line, MilaThreadCommandKind *out_kind);
typedef enum MilaMachineCommandKind { MILA_MACHINE_UNKNOWN = 0, MILA_MACHINE_LIST = 1, MILA_MACHINE_SHOW = 2, MILA_MACHINE_NEW = 3, MILA_MACHINE_RESIZE = 4, MILA_MACHINE_START = 5, MILA_MACHINE_STOP = 6, MILA_MACHINE_PAUSE = 7, MILA_MACHINE_RESUME = 8, MILA_MACHINE_DELETE = 9, MILA_MACHINE_SHARE_ADD = 10, MILA_MACHINE_SHARE_REMOVE = 11, MILA_MACHINE_WEB_SHOW = 12, MILA_MACHINE_WEB_SET = 13 } MilaMachineCommandKind;
MilaFfiStatus mila_machine_command_kind(const char *line, MilaMachineCommandKind *out_kind);
MilaFfiStatus mila_terminal_attach_validate(uint64_t from, uint16_t columns,
                                           uint16_t rows, uint8_t read_write);
MilaFfiStatus mila_terminal_input_validate(size_t length, uint8_t read_write);
MilaFfiStatus mila_terminal_resize_validate(uint16_t columns, uint16_t rows,
                                            uint8_t read_write);
/* Decodes one bounded watch line and returns only its event tag. */
MilaFfiStatus mila_watch_event_kind(const uint8_t *line, size_t length,
                                    MilaWatchEventKind *out_kind);
MilaFfiStatus mila_push_poke_validate(const uint8_t *envelope, size_t length,
                                      uint64_t now);

#ifdef __cplusplus
}
#endif
#endif

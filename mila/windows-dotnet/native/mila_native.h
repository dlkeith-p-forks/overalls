#ifndef MILA_NATIVE_H
#define MILA_NATIVE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MilaNativeVersion {
  uint32_t major;
  uint32_t minor;
} MilaNativeVersion;

/* Returns zero on success and writes a version to `out_version`. */
int32_t mila_native_version(MilaNativeVersion *out_version);

#ifdef __cplusplus
}
#endif

#endif

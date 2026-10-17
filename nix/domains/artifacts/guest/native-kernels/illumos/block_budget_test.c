/* SPDX-License-Identifier: BSD-2-Clause */
/* Execute the actual patched kernel helper; this is arithmetic evidence, not
 * native disk, DMA or ZFS acceptance evidence. */
#include <assert.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

typedef unsigned int uint_t;
typedef bool boolean_t;
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#include "block_budget_limit.inc"
#include "block_budget_function.inc"

static void check(uint_t queue, uint_t requested) {
  uint_t segments = requested;
  uint_t capacity = vioblk_request_capacity(queue, &segments, false);
  assert(capacity <= VIRTIO_BLK_REQ_BUFS);
  if (queue < 3 || requested == 0) {
    assert(capacity == 0);
  } else {
    assert(capacity > 0 && segments > 0 && segments <= requested);
    assert(segments <= queue - 2);
    assert((uint64_t)capacity * ((uint64_t)segments + 2) <= queue);
    assert(capacity == MIN(queue / (segments + 2), VIRTIO_BLK_REQ_BUFS));
  }
  segments = requested;
  capacity = vioblk_request_capacity(queue, &segments, true);
  assert(segments == requested);
  assert(capacity == (requested == 0 ? 0 : MIN(queue, VIRTIO_BLK_REQ_BUFS)));
}

/** @cc [owner:ghuntley,label:verification;capacity] native-block-budget-regressions
 * The extracted production helper MUST reserve data plus two metadata
 * descriptors per concurrent direct request, refuse undersized rings, clamp
 * scatter limits before overflow, and preserve indirect depth. Generated
 * vectors MUST include the production 256-descriptor/128-segment regression.
 */
int main(void) {
  uint_t segments = 128;
  assert(vioblk_request_capacity(256, &segments, false) == 1);
  assert(segments == 128);
  segments = 1;
  assert(vioblk_request_capacity(256, &segments, false) == 85);
  segments = 128;
  assert(vioblk_request_capacity(8, &segments, false) == 1);
  assert(segments == 6);
  for (uint_t queue = 0; queue <= 1024; queue++) {
    for (uint_t data = 0; data <= 256; data++)
      check(queue, data);
    check(queue, UINT_MAX);
    check(queue, UINT_MAX - 1);
  }
  const uint_t boundaries[] = {0, 1, 2, 3, 255, 256, 257, 65535,
                              UINT_MAX - 2, UINT_MAX - 1, UINT_MAX};
  for (uint_t i = 0; i < sizeof(boundaries) / sizeof(boundaries[0]); i++)
    for (uint_t j = 0; j < sizeof(boundaries) / sizeof(boundaries[0]); j++)
      check(boundaries[i], boundaries[j]);
  puts("block descriptor budget: 265596 generated and boundary vectors passed");
  return 0;
}

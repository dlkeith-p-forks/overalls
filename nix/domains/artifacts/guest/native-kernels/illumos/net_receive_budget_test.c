/* SPDX-License-Identifier: BSD-2-Clause */
/* Execute the actual patched kernel helper; this is arithmetic evidence, not
 * native network, DMA or Firecracker acceptance evidence. */
#include <assert.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

typedef unsigned int uint_t;
typedef bool boolean_t;
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#include "net_receive_budget_function.inc"

static void check(uint_t queue, uint_t buffers, uint_t cookies) {
  uint_t loans = vioif_rx_loan_limit(queue, buffers, cookies, false);
  assert(loans <= buffers / 2);
  if (cookies == 0 || cookies >= queue) {
    assert(loans == 0);
  } else {
    uint64_t per_buffer = (uint64_t)cookies + 1;
    uint64_t held = (uint64_t)loans * per_buffer;
    assert(loans == MIN(buffers, queue / (cookies + 1)) / 2);
    /* Loaned buffers hold at most half of the ring's descriptors. */
    assert(held * 2 <= queue);
    /* Whenever the ring fits one buffer, one can still be posted. */
    if (buffers > 0 && queue / per_buffer >= 1)
      assert((uint64_t)queue - held >= per_buffer);
  }
  loans = vioif_rx_loan_limit(queue, buffers, cookies, true);
  assert(loans == MIN(buffers, queue) / 2);
}

/** @cc [owner:ghuntley,label:verification;capacity] native-net-receive-budget-regressions
 * The extracted production helper MUST bound direct receive loans by half the
 * buffers the ring can hold, refuse loans when one buffer cannot fit, and keep
 * indirect loans at half the ring and pool. Generated vectors MUST include the
 * production 256-descriptor ring with 17-cookie 64 KiB buffers that exhausted
 * the ring under Firecracker.
 */
int main(void) {
  /* 64 KiB buffers: 17 data cookies plus the header, 14 buffers per ring. */
  assert(vioif_rx_loan_limit(256, 256, 17, false) == 7);
  /* The former limit allowed 128 loans, far beyond the 14 that fit. */
  assert(256 / 2 > 256 / (17 + 1));
  /* Page-sized buffers: one data cookie plus the header. */
  assert(vioif_rx_loan_limit(256, 256, 1, false) == 64);
  assert(vioif_rx_loan_limit(256, 256, 1, true) == 128);
  assert(vioif_rx_loan_limit(2, 256, 1, false) == 0);
  for (uint_t queue = 0; queue <= 1024; queue++) {
    for (uint_t cookies = 0; cookies <= 300; cookies++) {
      check(queue, 256, cookies);
      check(queue, queue, cookies);
    }
    check(queue, 256, UINT_MAX);
    check(queue, UINT_MAX, UINT_MAX - 1);
  }
  const uint_t boundaries[] = {0, 1, 2, 3, 255, 256, 257, 65535,
                              UINT_MAX - 2, UINT_MAX - 1, UINT_MAX};
  const uint_t count = sizeof(boundaries) / sizeof(boundaries[0]);
  for (uint_t i = 0; i < count; i++)
    for (uint_t j = 0; j < count; j++)
      for (uint_t k = 0; k < count; k++)
        check(boundaries[i], boundaries[j], boundaries[k]);
  puts("net receive descriptor budget: generated and boundary vectors passed");
  return 0;
}

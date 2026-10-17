/* SPDX-License-Identifier: BSD-2-Clause */
/* Actual patched vioblk functions under a one-request, reentrant blkdev mock.
 * This is host control-flow evidence, not native DMA or storage acceptance. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef bool boolean_t;
typedef unsigned int uint_t;
typedef struct { bool held; } kmutex_t;
typedef struct { unsigned int unused; } kcondvar_t;
typedef struct { void *next, *previous; } list_node_t;
typedef struct { unsigned int identity; } bd_xfer_t;
typedef struct vioblk_req vioblk_req_t;
typedef struct {
  vioblk_req_t *request;
  unsigned int descriptors;
} virtio_chain_t;
typedef struct { uint8_t bytes[32]; } virtio_dma_t;
typedef struct { vioblk_req_t *head; } list_t;
typedef struct { virtio_chain_t *completion; } virtio_queue_t;
typedef struct { struct { uint64_t ui64; } value; } counter_t;
typedef struct {
  counter_t vbs_rw_cacheflush, vbs_io_errors, vbs_unsupp_errors, vbs_nxio_errors;
} vioblk_stats_t;
typedef struct {
  kmutex_t vib_mutex;
  kcondvar_t vib_cv;
  list_t vib_reqs;
  uint_t vib_nreqs_alloc;
  vioblk_stats_t *vib_stats;
  virtio_queue_t *vib_vq;
} vioblk_t;

#define __packed __attribute__((__packed__))
#define B_TRUE true
#define B_FALSE false
#define DDI_SUCCESS 0
#define DDI_FAILURE (-1)
#define DDI_DMA_SYNC_FORDEV 1
#define DDI_DMA_SYNC_FORCPU 2
#define VIRTIO_DIR_DEVICE_WRITES 1
#define VERIFY assert
#define VERIFY0(value) assert((value) == 0)
#define VERIFY3P(left, op, right) assert((left) op (right))
#define VERIFY3S(left, op, right) assert((left) op (right))
#define VERIFY3U(left, op, right) assert((left) op (right))
#define MUTEX_HELD(lock) ((lock)->held)
#define bcopy(source, destination, count) memcpy(destination, source, count)

#include "block_completion_types.inc"
_Static_assert(sizeof(struct vioblk_req_hdr) == 16, "native request header");

static uint_t vioblk_poll(vioblk_t *);
static vioblk_req_t *vioblk_req_alloc(vioblk_t *);
static void vioblk_req_free(vioblk_t *, vioblk_req_t *);
static void bd_xfer_done(bd_xfer_t *, int);
static vioblk_t *current;
static bd_xfer_t original = {1}, replacement = {2};
static bool reenter, panicking, append_failure;
static unsigned int cleared, submitted, callbacks, broadcasts, waits, delays;
static int observed_error;

static void mutex_enter(kmutex_t *lock) {
  assert(!lock->held);
  lock->held = true;
}
static void mutex_exit(kmutex_t *lock) {
  assert(lock->held);
  lock->held = false;
}
static vioblk_req_t *list_remove_head(list_t *list) {
  vioblk_req_t *request = list->head;
  list->head = NULL;
  return request;
}
static void list_insert_head(list_t *list, vioblk_req_t *request) {
  assert(list->head == NULL);
  list->head = request;
}
static void virtio_chain_clear(virtio_chain_t *chain) {
  assert(chain->descriptors > 0);
  chain->descriptors = 0;
  cleared++;
}
static int virtio_chain_append(virtio_chain_t *chain, uint64_t address,
                              size_t bytes, int direction) {
  assert(address == 0x1000 + sizeof(struct vioblk_req_hdr));
  assert(bytes == 1 && direction == VIRTIO_DIR_DEVICE_WRITES);
  if (append_failure)
    return DDI_FAILURE;
  chain->descriptors++;
  return DDI_SUCCESS;
}
static uint64_t virtio_dma_cookie_pa(virtio_dma_t *dma, uint_t cookie) {
  assert(dma != NULL && cookie == 0);
  return 0x1000;
}
static void virtio_dma_sync(virtio_dma_t *dma, int direction) {
  assert(dma != NULL);
  assert(direction == DDI_DMA_SYNC_FORDEV || direction == DDI_DMA_SYNC_FORCPU);
}
static void *virtio_dma_va(virtio_dma_t *dma, size_t offset) {
  assert(offset < sizeof(dma->bytes));
  return dma->bytes + offset;
}
static void virtio_chain_submit(virtio_chain_t *chain, boolean_t flush) {
  assert(flush && chain->descriptors == 2);
  assert(current->vib_vq->completion == NULL);
  current->vib_vq->completion = chain;
  submitted++;
}
static virtio_chain_t *virtio_queue_poll(virtio_queue_t *queue) {
  virtio_chain_t *chain = queue->completion;
  queue->completion = NULL;
  return chain;
}
static void *virtio_chain_data(virtio_chain_t *chain) { return chain->request; }
static bool ddi_in_panic(void) { return panicking; }
static void drv_usecwait(unsigned int usec) {
  assert(usec == 10 && panicking);
  delays++;
}
static void cv_wait(kcondvar_t *cv, kmutex_t *lock) {
  assert(cv == &current->vib_cv && lock->held && !panicking);
  waits++;
  assert(vioblk_poll(current) == 1);
}
static void cv_broadcast(kcondvar_t *cv) {
  assert(cv == &current->vib_cv);
  broadcasts++;
}

#include "block_completion_functions.inc"

static void bd_xfer_done(bd_xfer_t *xfer, int error) {
  assert(!current->vib_mutex.held && xfer == &original);
  assert(current->vib_nreqs_alloc == 0 && cleared == 1);
  callbacks++;
  observed_error = error;
  if (reenter) {
    mutex_enter(&current->vib_mutex);
    vioblk_req_t *request = vioblk_req_alloc(current);
    assert(request != NULL && request->vbr_chain->descriptors == 0);
    request->vbr_xfer = &replacement;
    request->vbr_error = 1234;
    request->vbr_type = VIRTIO_BLK_T_GET_ID;
    request->vbr_seqno = UINT64_C(0x123456789);
    request->vbr_status |= VIOBLK_REQSTAT_INFLIGHT;
    request->vbr_chain->descriptors = 17;
    mutex_exit(&current->vib_mutex);
  }
}

struct fixture {
  vioblk_t device;
  vioblk_req_t request;
  vioblk_stats_t statistics;
  virtio_chain_t chain;
  virtio_dma_t dma;
  virtio_queue_t queue;
};

static vioblk_req_t *prepare(struct fixture *fixture, bool framework, bool polled,
                             int type, uint8_t status) {
  memset(fixture, 0, sizeof(*fixture));
  current = &fixture->device;
  current->vib_stats = &fixture->statistics;
  current->vib_vq = &fixture->queue;
  current->vib_reqs.head = &fixture->request;
  fixture->request.vbr_chain = &fixture->chain;
  fixture->request.vbr_dma = &fixture->dma;
  fixture->chain.request = &fixture->request;
  fixture->dma.bytes[sizeof(struct vioblk_req_hdr)] = status;
  cleared = submitted = callbacks = broadcasts = waits = delays = 0;
  observed_error = -1;
  append_failure = false;
  mutex_enter(&current->vib_mutex);
  vioblk_req_t *request = vioblk_req_alloc(current);
  assert(request == &fixture->request && current->vib_nreqs_alloc == 1);
  assert(vioblk_req_alloc(current) == NULL);
  request->vbr_xfer = framework ? &original : NULL;
  request->vbr_type = type;
  request->vbr_status |= polled ? VIOBLK_REQSTAT_POLLED : 0;
  fixture->chain.descriptors = 1;
  return request;
}

static void finish(struct fixture *fixture, bool framework) {
  assert(current->vib_mutex.held && cleared == 1);
  assert(callbacks == (unsigned int)framework);
  if (framework && reenter) {
    vioblk_req_t *request = &fixture->request;
    assert(current->vib_nreqs_alloc == 1 && current->vib_reqs.head == NULL);
    assert(request->vbr_status ==
           (VIOBLK_REQSTAT_ALLOCATED | VIOBLK_REQSTAT_INFLIGHT));
    assert(request->vbr_xfer == &replacement && request->vbr_error == 1234);
    assert(request->vbr_type == VIRTIO_BLK_T_GET_ID);
    assert(request->vbr_seqno == UINT64_C(0x123456789));
    assert(fixture->chain.descriptors == 17);
    vioblk_req_free(current, request);
    assert(cleared == 2);
  }
  assert(current->vib_nreqs_alloc == 0);
  assert(current->vib_reqs.head == &fixture->request);
  assert(fixture->request.vbr_status == 0 && fixture->request.vbr_xfer == NULL);
  assert(fixture->request.vbr_error == 0 && fixture->chain.descriptors == 0);
  mutex_exit(&current->vib_mutex);
}

static int status_error(uint8_t status) {
  switch (status) {
  case VIRTIO_BLK_S_OK: return 0;
  case VIRTIO_BLK_S_IOERR: return EIO;
  case VIRTIO_BLK_S_UNSUPP: return ENOTTY;
  default: return ENXIO;
  }
}

/** @cc [owner:ghuntley,label:verification;recovery] native-block-completion-reentrancy-test
 * Actual request allocation/free, completion, submit and poll bodies MUST return
 * the sole request and descriptors before blkdev callback reentry, preserve the
 * original callback error and leave a replacement request intact. External
 * completion MUST return success after its one callback consumes the result;
 * internal completion MUST return its original error. Polled/internal and
 * asynchronous callers MUST release once and retain flush/error accounting.
 * Host mocks and sanitizers MUST NOT establish native storage or DMA safety.
 */
int main(void) {
  const uint8_t statuses[] = {VIRTIO_BLK_S_OK, VIRTIO_BLK_S_IOERR,
                            VIRTIO_BLK_S_UNSUPP, 255};
  struct fixture fixture;
  for (unsigned int framework = 0; framework < 2; framework++) {
    for (unsigned int reuse = 0; reuse < 2; reuse++) {
      reenter = reuse;
      for (unsigned int flush = 0; flush < 2; flush++) {
        for (unsigned int index = 0; index < sizeof(statuses); index++) {
          int type = flush ? VIRTIO_BLK_T_FLUSH : VIRTIO_BLK_T_OUT;
          int expected = status_error(statuses[index]);
          vioblk_req_t *request = prepare(&fixture, framework, false, type,
                                          statuses[index]);
          request->vbr_error = expected;
          assert(vioblk_complete(current, request) == (framework ? 0 : expected));
          assert(!framework || observed_error == expected);
          assert(fixture.statistics.vbs_rw_cacheflush.value.ui64 == flush);
          finish(&fixture, framework);
          for (unsigned int polled = 0; polled < 2; polled++) {
            for (unsigned int panic = 0; panic < 2; panic++) {
              panicking = panic;
              request = prepare(&fixture, framework, polled, type, statuses[index]);
              int result = vioblk_common_submit(current, request);
              assert(submitted == 1);
              if (polled) {
                assert(result == (framework ? 0 : expected) && broadcasts == 1);
                assert(waits == (unsigned int)!panic && delays == panic);
              } else {
                assert(result == 0 && cleared == 0 && callbacks == 0);
                assert(current->vib_nreqs_alloc == 1);
                assert(vioblk_poll(current) == 1);
                assert(broadcasts == 0 && waits == 0 && delays == 0);
              }
              assert(vioblk_poll(current) == 0);
              assert(!framework || observed_error == expected);
              assert(fixture.statistics.vbs_rw_cacheflush.value.ui64 == flush);
              assert(fixture.statistics.vbs_io_errors.value.ui64 ==
                     (statuses[index] == VIRTIO_BLK_S_IOERR));
              assert(fixture.statistics.vbs_unsupp_errors.value.ui64 ==
                     (statuses[index] == VIRTIO_BLK_S_UNSUPP));
              assert(fixture.statistics.vbs_nxio_errors.value.ui64 ==
                     (statuses[index] == 255));
              finish(&fixture, framework);
            }
          }
        }
      }
    }
  }
  reenter = false;
  vioblk_req_t *request = prepare(&fixture, true, false, VIRTIO_BLK_T_FLUSH, 0);
  append_failure = true;
  assert(vioblk_common_submit(current, request) == ENOMEM);
  assert(cleared == 1 && submitted == 0 && callbacks == 0);
  assert(current->vib_nreqs_alloc == 0 && current->vib_reqs.head == request);
  assert(fixture.statistics.vbs_rw_cacheflush.value.ui64 == 0);
  assert(vioblk_poll(current) == 0 && broadcasts == 0);
  mutex_exit(&current->vib_mutex);
  return 0;
}

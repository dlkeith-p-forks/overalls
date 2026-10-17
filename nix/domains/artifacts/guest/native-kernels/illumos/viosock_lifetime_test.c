/* SPDX-License-Identifier: BSD-2-Clause */
/* Execute extracted driver functions with native API fault injection. This is
 * host evidence for control flow, not native interrupt or DMA acceptance. */
#include "ov_vsock.h"
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef bool boolean_t;
typedef unsigned int uint_t;
typedef char *caddr_t;
typedef int ddi_attach_cmd_t;
typedef int ddi_detach_cmd_t;
typedef struct {
  bool initialized, held;
} kmutex_t;
typedef struct {
  void *private;
} dev_info_t;
typedef struct {
  unsigned int unused;
} taskq_t;
typedef struct {
  unsigned int unused;
} taskq_ent_t;
typedef struct virtio virtio_t;
typedef struct virtio_queue virtio_queue_t;
typedef struct virtio_chain virtio_chain_t;
typedef struct {
  unsigned int cookies;
} virtio_dma_t;
struct virtio_chain {
  virtio_queue_t *queue;
  bool inflight;
  void *data;
};
struct virtio_queue {
  virtio_t *vio;
  virtio_chain_t *chains[64];
};
struct virtio {
  virtio_queue_t *queues[3];
  bool active;
};

#define B_TRUE true
#define B_FALSE false
#define DDI_SUCCESS 0
#define DDI_FAILURE (-1)
#define DDI_ATTACH 1
#define DDI_DETACH 2
#define DDI_RESUME 3
#define DDI_SUSPEND 4
#define KM_SLEEP 1
#define MUTEX_DRIVER 1
#define TASKQ_PREPOPULATE 1
#define DDI_DMA_CONSISTENT 1
#define DDI_DMA_WRITE 2
#define DDI_DMA_READ 4
#define DDI_DMA_SYNC_FORDEV 1
#define VIRTIO_DIR_DEVICE_WRITES 1
#define VIRTIO_ANY_INTR_TYPE 0
#define VERIFY assert
#define MIN(a, b) ((a) < (b) ? (a) : (b))
static const int ov_dma_attr, minclsyspri;

enum kind { DEVICE, FRAMEWORK, QUEUE, CHAIN, DMA, TASKQ };
enum fault {
  NONE,
  INIT,
  FEATURES,
  CID,
  QUEUE_ALLOC,
  TASKQ_ALLOC,
  CHAIN_ALLOC,
  DMA_ALLOC,
  DMA_COOKIES,
  CHAIN_APPEND,
  INIT_COMPLETE,
  INTERRUPTS
};
struct allocation {
  void *pointer;
  enum kind kind;
};
static struct allocation allocations[1024];
static unsigned int allocated, destroys, waits, callbacks, reports, interrupts;
static enum fault injected;
static unsigned int target, matched;
static bool activated;

static bool fail(enum fault point) {
  if (injected != point)
    return false;
  return ++matched == target;
}
static void *allocate(enum kind kind, size_t bytes) {
  assert(allocated < sizeof(allocations) / sizeof(allocations[0]));
  void *pointer = calloc(1, bytes);
  assert(pointer != NULL);
  allocations[allocated++] = (struct allocation){pointer, kind};
  return pointer;
}
static void release(void *pointer, enum kind kind) {
  assert(!activated);
  for (unsigned int n = 0; n < allocated; n++) {
    if (allocations[n].pointer == pointer) {
      assert(allocations[n].kind == kind);
      allocations[n].pointer = NULL;
      free(pointer);
      return;
    }
  }
  assert(false);
}
static unsigned int live(enum kind kind) {
  unsigned int count = 0;
  for (unsigned int n = 0; n < allocated; n++)
    if (allocations[n].pointer != NULL && allocations[n].kind == kind)
      count++;
  return count;
}
static void mutex_init(kmutex_t *lock, void *name, int type, void *priority) {
  (void)name;
  (void)type;
  (void)priority;
  assert(!lock->initialized);
  lock->initialized = true;
}
static void mutex_enter(kmutex_t *lock) {
  assert(lock->initialized && !lock->held);
  lock->held = true;
}
static void mutex_exit(kmutex_t *lock) {
  assert(lock->initialized && lock->held);
  lock->held = false;
}
static void mutex_destroy(kmutex_t *lock) {
  assert(lock->initialized && !lock->held);
  lock->initialized = false;
}
static void *kmem_zalloc(size_t bytes, int flags) {
  assert(flags == KM_SLEEP);
  return allocate(DEVICE, bytes);
}
static void kmem_free(void *pointer, size_t bytes) {
  (void)bytes;
  destroys++;
  release(pointer, DEVICE);
}
static virtio_t *virtio_init(dev_info_t *dip) {
  (void)dip;
  return fail(INIT) ? NULL : allocate(FRAMEWORK, sizeof(virtio_t));
}
static bool virtio_init_features(virtio_t *vio, uint64_t features,
                                 bool indirect) {
  assert(vio != NULL && features == 0 && !indirect);
  return !fail(FEATURES);
}
static uint64_t virtio_dev_get64(virtio_t *vio, unsigned int offset) {
  assert(vio != NULL && offset == 0);
  return fail(CID) ? 4 : 3;
}
static virtio_queue_t *
virtio_queue_alloc(virtio_t *vio, unsigned int index, const char *name,
                   unsigned int (*handler)(caddr_t, caddr_t), void *argument,
                   bool indirect, unsigned int segments) {
  (void)name;
  (void)handler;
  (void)argument;
  assert(index < 3 && !indirect && segments == 1 && !vio->active);
  if (fail(QUEUE_ALLOC))
    return NULL;
  virtio_queue_t *queue = allocate(QUEUE, sizeof(*queue));
  queue->vio = vio;
  vio->queues[index] = queue;
  return queue;
}
static unsigned int virtio_queue_size(virtio_queue_t *queue) {
  assert(queue != NULL);
  return 32;
}
static void virtio_register_cfgchange_handler(
    virtio_t *vio, unsigned int (*handler)(caddr_t, caddr_t), void *argument) {
  assert(vio != NULL && handler != NULL && argument != NULL && !vio->active);
}
static taskq_t *taskq_create(const char *name, int threads, int priority,
                             int minalloc, int maxalloc, int flags) {
  (void)name;
  (void)priority;
  assert(threads == 1 && minalloc == 2 && maxalloc == 2 &&
         flags == TASKQ_PREPOPULATE);
  return fail(TASKQ_ALLOC) ? NULL : allocate(TASKQ, sizeof(taskq_t));
}
static void taskq_wait(taskq_t *queue) {
  assert(queue != NULL);
  waits++;
}
static void taskq_destroy(taskq_t *queue) { release(queue, TASKQ); }
static virtio_chain_t *virtio_chain_alloc(virtio_queue_t *queue, int flags) {
  assert(queue != NULL && flags == KM_SLEEP && !queue->vio->active);
  if (fail(CHAIN_ALLOC))
    return NULL;
  virtio_chain_t *chain = allocate(CHAIN, sizeof(*chain));
  chain->queue = queue;
  for (unsigned int n = 0; n < 64; n++) {
    if (queue->chains[n] == NULL) {
      queue->chains[n] = chain;
      return chain;
    }
  }
  assert(false);
  return NULL;
}
static virtio_dma_t *virtio_dma_alloc(virtio_t *vio, size_t bytes,
                                      const int *attributes, int flags,
                                      int sleep) {
  assert(!vio->active && bytes > 0 && attributes == &ov_dma_attr &&
         sleep == KM_SLEEP);
  assert(flags == (DDI_DMA_CONSISTENT | DDI_DMA_WRITE) ||
         flags == (DDI_DMA_CONSISTENT | DDI_DMA_READ));
  if (fail(DMA_ALLOC))
    return NULL;
  virtio_dma_t *dma = allocate(DMA, sizeof(*dma));
  dma->cookies = fail(DMA_COOKIES) ? 2 : 1;
  return dma;
}
static unsigned int virtio_dma_ncookies(virtio_dma_t *dma) {
  return dma->cookies;
}
static void virtio_chain_data_set(virtio_chain_t *chain, void *data) {
  chain->data = data;
}
static uintptr_t virtio_dma_cookie_pa(virtio_dma_t *dma, unsigned int index) {
  assert(index == 0);
  return (uintptr_t)dma;
}
static int virtio_chain_append(virtio_chain_t *chain, uintptr_t address,
                               size_t bytes, int direction) {
  assert(chain != NULL && address != 0 && bytes > 0 &&
         direction == VIRTIO_DIR_DEVICE_WRITES);
  return fail(CHAIN_APPEND) ? DDI_FAILURE : DDI_SUCCESS;
}
static void virtio_dma_sync(virtio_dma_t *dma, int direction) {
  assert(dma != NULL && direction == DDI_DMA_SYNC_FORDEV);
}
static void virtio_chain_submit(virtio_chain_t *chain, bool flush) {
  assert(!chain->inflight && !flush && !chain->queue->vio->active);
  chain->inflight = true;
}
static void virtio_chain_free(virtio_chain_t *chain) {
  assert(!chain->inflight);
  for (unsigned int n = 0; n < 64; n++)
    if (chain->queue->chains[n] == chain)
      chain->queue->chains[n] = NULL;
  release(chain, CHAIN);
}
static void virtio_dma_free(virtio_dma_t *dma) { release(dma, DMA); }
static int virtio_init_complete(virtio_t *vio, int types) {
  assert(types == VIRTIO_ANY_INTR_TYPE && live(TASKQ) == 1 && live(DMA) == 65);
  if (fail(INIT_COMPLETE))
    return DDI_FAILURE;
  vio->active = activated = true;
  return DDI_SUCCESS;
}
static void *virtio_intr_pri(virtio_t *vio) {
  assert(vio->active);
  return NULL;
}
static void virtio_queue_flush(virtio_queue_t *queue) {
  assert(queue->vio->active);
}
static int virtio_interrupts_enable(virtio_t *vio) {
  assert(vio->active);
  return fail(INTERRUPTS) ? DDI_FAILURE : DDI_SUCCESS;
}
static void virtio_interrupts_disable(virtio_t *vio) {
  assert(vio->active);
  interrupts++;
}
static void virtio_shutdown(virtio_t *vio) { assert(!vio->active); }
static virtio_chain_t *virtio_queue_evacuate(virtio_queue_t *queue) {
  assert(!queue->vio->active);
  for (unsigned int n = 0; n < 64; n++) {
    virtio_chain_t *chain = queue->chains[n];
    if (chain != NULL && chain->inflight) {
      chain->inflight = false;
      return chain;
    }
  }
  return NULL;
}
static void virtio_fini(virtio_t *vio, bool failed) {
  assert(!failed && !vio->active);
  for (unsigned int n = 0; n < 3; n++) {
    if (vio->queues[n] == NULL)
      continue;
    for (unsigned int slot = 0; slot < 64; slot++)
      assert(vio->queues[n]->chains[slot] == NULL);
    release(vio->queues[n], QUEUE);
  }
  release(vio, FRAMEWORK);
}
static void ddi_set_driver_private(dev_info_t *dip, void *data) {
  dip->private = data;
}
static void ddi_report_dev(dev_info_t *dip) {
  assert(dip->private != NULL);
  reports++;
}

#include "viosock_lifetime_types.inc"
static kmutex_t ov_global_lock;
static struct ov_device *ov_device;
static unsigned int ov_interrupt(caddr_t argument, caddr_t unused) {
  (void)unused;
  struct ov_device *device = (void *)argument;
  assert(device->initialized && device->taskq != NULL && device->online);
  return 1;
}
static unsigned int ov_configuration_changed(caddr_t argument, caddr_t unused) {
  (void)argument;
  (void)unused;
  return 1;
}
static void ov_callback(const struct ov_vsock_header *header,
                        const uint8_t *payload, bool reset) {
  assert(header == NULL && payload == NULL && reset);
  callbacks++;
}
#include "viosock_lifetime_functions.inc"

static void dispose_vm(void) {
  /* Explicit test disposal models VM lifetime end, never native detach. */
  for (unsigned int n = 0; n < allocated; n++)
    free(allocations[n].pointer);
  memset(allocations, 0, sizeof(allocations));
  allocated = destroys = waits = callbacks = reports = interrupts = matched = 0;
  activated = false;
  ov_device = NULL;
  ov_global_lock = (kmutex_t){.initialized = true};
}
static void preactivation_failure(enum fault fault, unsigned int index) {
  dispose_vm();
  injected = fault;
  target = index;
  dev_info_t dip = {0};
  assert(ov_attach(&dip, DDI_ATTACH) == DDI_FAILURE);
  assert(matched == index && !activated && dip.private == NULL &&
         ov_device == NULL);
  assert(destroys == 1 && callbacks == 0 && reports == 0);
  for (enum kind kind = DEVICE; kind <= TASKQ; kind++)
    assert(live(kind) == 0);
}
/**
 * @cc [owner:ghuntley,label:verification;recovery] native-driver-lifetime-faults
 * Actual extracted attach/cleanup/detach code
 * MUST release all allocations on every injected failure before DRIVER_OK. Late
 * interrupt or singleton failure MUST retain all interrupt-visible allocations,
 * fence availability and retain driver-private ownership. Every runtime detach
 * command MUST refuse. This host mock/sanitizer result MUST NOT establish
 * native DMA or interrupt safety.
 */
int main(void) {
  const enum fault single[] = {INIT, FEATURES, CID, TASKQ_ALLOC, INIT_COMPLETE};
  for (unsigned int n = 0; n < sizeof(single) / sizeof(single[0]); n++)
    preactivation_failure(single[n], 1);
  for (unsigned int n = 1; n <= 3; n++)
    preactivation_failure(QUEUE_ALLOC, n);
  for (unsigned int n = 1; n <= 65; n++) {
    preactivation_failure(CHAIN_ALLOC, n);
    preactivation_failure(DMA_ALLOC, n);
    preactivation_failure(DMA_COOKIES, n);
  }
  for (unsigned int n = 1; n <= 33; n++)
    preactivation_failure(CHAIN_APPEND, n);
  for (unsigned int duplicate = 0; duplicate < 2; duplicate++) {
    dispose_vm();
    injected = duplicate ? NONE : INTERRUPTS;
    target = 1;
    struct ov_device existing = {0};
    if (duplicate)
      ov_device = &existing;
    dev_info_t dip = {0};
    assert(ov_attach(&dip, DDI_ATTACH) == DDI_SUCCESS);
    struct ov_device *retained = dip.private;
    assert(retained != NULL && retained->activated && retained->stopping &&
           !retained->online);
    assert(ov_device == (duplicate ? &existing : NULL));
    assert(live(DEVICE) == 1 && live(FRAMEWORK) == 1 && live(QUEUE) == 3);
    assert(live(CHAIN) == 65 && live(DMA) == 65 && live(TASKQ) == 1);
    assert(destroys == 0 && waits == 1 && callbacks == 1 && reports == 0 &&
           interrupts == 1);
    for (int command = DDI_DETACH; command <= DDI_SUSPEND; command++)
      assert(ov_detach(&dip, command) == DDI_FAILURE);
    assert(live(DMA) == 65 && dip.private == retained);
  }
  dispose_vm();
  injected = NONE;
  target = 1;
  dev_info_t dip = {0};
  assert(ov_attach(&dip, DDI_RESUME) == DDI_FAILURE && allocated == 0);
  assert(ov_attach(&dip, DDI_ATTACH) == DDI_SUCCESS);
  struct ov_device *device = dip.private;
  assert(device == ov_device && device->online && !device->stopping &&
         device->activated);
  assert(live(DMA) == 65 && destroys == 0 && reports == 1 && callbacks == 0);
  assert(ov_detach(&dip, DDI_DETACH) == DDI_FAILURE && live(DMA) == 65);
  dispose_vm();
  return 0;
}

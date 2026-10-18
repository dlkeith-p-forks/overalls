/* SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Overalls contributors.
 */
#include <sys/types.h>
#include <sys/conf.h>
#include <sys/modctl.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/taskq.h>
#include <sys/taskq_impl.h>
#include <sys/disp.h>
#include <sys/sysmacros.h>
#include <sys/byteorder.h>
#include <sys/errno.h>
#include <sys/debug.h>
#include "virtio.h"
#include "viosock.h"

#define OV_SLOTS 32U
#define OV_FRAME (OV_VSOCK_HEADER_BYTES + OV_VSOCK_MAX_PAYLOAD)

struct ov_slot {
	virtio_dma_t *dma;
	virtio_chain_t *chain;
	boolean_t busy;
};

struct ov_device {
	dev_info_t *dip;
	virtio_t *vio;
	virtio_queue_t *queue[3];
	struct ov_slot rx[OV_SLOTS];
	struct ov_slot tx[OV_SLOTS];
	struct ov_slot event;
	uint_t nrx;
	uint_t ntx;
	kmutex_t lock;
	taskq_t *taskq;
	taskq_ent_t work_entry;
	boolean_t initialized;
	boolean_t activated;
	boolean_t stopping;
	boolean_t queued;
	boolean_t online;
	boolean_t reset_failed;
	boolean_t configuration_pending;
};

static kmutex_t ov_global_lock;
static kcondvar_t ov_callback_cv;
static struct ov_device *ov_device;
static viosock_receive_f ov_receive;
static viosock_notify_f ov_reset;
static viosock_notify_f ov_writable;
static void *ov_sink;
static uint_t ov_callbacks;
static boolean_t ov_unsubscribing;

static int ov_attach(dev_info_t *, ddi_attach_cmd_t);
static int ov_detach(dev_info_t *, ddi_detach_cmd_t);
static int ov_quiesce(dev_info_t *);
static void ov_worker(void *);

static struct dev_ops ov_dev_ops = {
	.devo_rev = DEVO_REV,
	.devo_getinfo = ddi_no_info,
	.devo_identify = nulldev,
	.devo_probe = nulldev,
	.devo_attach = ov_attach,
	.devo_detach = ov_detach,
	.devo_reset = nodev,
	.devo_quiesce = ov_quiesce
};

static struct modldrv ov_modldrv = {
	&mod_driverops, "Bounded host-only virtio-vsock", &ov_dev_ops
};
static struct modlinkage ov_modlinkage = {
	MODREV_1, { &ov_modldrv, NULL }
};

static const ddi_dma_attr_t ov_dma_attr = {
	.dma_attr_version = DMA_ATTR_V0,
	.dma_attr_addr_lo = 0,
	.dma_attr_addr_hi = UINT64_MAX,
	.dma_attr_count_max = UINT32_MAX,
	.dma_attr_align = 1,
	.dma_attr_burstsizes = 1,
	.dma_attr_minxfer = 1,
	.dma_attr_maxxfer = UINT32_MAX,
	.dma_attr_seg = UINT64_MAX,
	.dma_attr_sgllen = 1,
	.dma_attr_granular = 1
};

int
viosock_subscribe(viosock_receive_f receive, viosock_notify_f reset,
    viosock_notify_f writable, void *sink)
{
	if (receive == NULL || reset == NULL || writable == NULL)
		return (EINVAL);
	mutex_enter(&ov_global_lock);
	if (ov_receive != NULL || ov_unsubscribing) {
		mutex_exit(&ov_global_lock);
		return (EBUSY);
	}
	ov_receive = receive;
	ov_reset = reset;
	ov_writable = writable;
	ov_sink = sink;
	mutex_exit(&ov_global_lock);
	return (0);
}

void
viosock_unsubscribe(void *sink)
{
	mutex_enter(&ov_global_lock);
	if (ov_unsubscribing && ov_sink == sink) {
		while (ov_unsubscribing)
			cv_wait(&ov_callback_cv, &ov_global_lock);
	} else if (ov_receive != NULL && ov_sink == sink) {
		ov_unsubscribing = B_TRUE;
		ov_receive = NULL;
		ov_reset = NULL;
		ov_writable = NULL;
		while (ov_callbacks != 0)
			cv_wait(&ov_callback_cv, &ov_global_lock);
		ov_sink = NULL;
		ov_unsubscribing = B_FALSE;
		cv_broadcast(&ov_callback_cv);
	}
	mutex_exit(&ov_global_lock);
}

static void
ov_callback(const struct ov_vsock_header *header, const uint8_t *payload,
    boolean_t reset)
{
	viosock_receive_f receive;
	viosock_notify_f notify;
	void *sink;

	mutex_enter(&ov_global_lock);
	receive = ov_receive;
	notify = reset ? ov_reset : ov_writable;
	sink = ov_sink;
	if ((header != NULL && receive == NULL) ||
	    (header == NULL && notify == NULL)) {
		mutex_exit(&ov_global_lock);
		return;
	}
	ov_callbacks++;
	mutex_exit(&ov_global_lock);
	if (header != NULL)
		receive(sink, header, payload);
	else
		notify(sink);
	mutex_enter(&ov_global_lock);
	if (--ov_callbacks == 0)
		cv_broadcast(&ov_callback_cv);
	mutex_exit(&ov_global_lock);
}

const char *
viosock_build_id(void)
{
	return (OV_VSOCK_BUILD_ID);
}

boolean_t
viosock_ready(void)
{
	boolean_t ready = B_FALSE;
	mutex_enter(&ov_global_lock);
	if (ov_device != NULL) {
		mutex_enter(&ov_device->lock);
		ready = ov_device->online && !ov_device->stopping;
		mutex_exit(&ov_device->lock);
	}
	mutex_exit(&ov_global_lock);
	return (ready);
}

int
viosock_xmit(const struct ov_vsock_header *header, const void *payload)
{
	struct ov_device *device;
	struct ov_slot *slot = NULL;
	int error = 0;
	uint8_t encoded[OV_VSOCK_HEADER_BYTES];

	if (header == NULL || (header->len != 0 && payload == NULL) ||
	    ov_vsock_encode(encoded, sizeof (encoded), header) != OV_VSOCK_OK)
		return (EINVAL);
	mutex_enter(&ov_global_lock);
	if ((device = ov_device) == NULL) {
		mutex_exit(&ov_global_lock);
		return (ENXIO);
	}
	mutex_enter(&device->lock);
	mutex_exit(&ov_global_lock);
	if (!device->online || device->stopping) {
		error = ENXIO;
		goto out;
	}
	/* Reserve control capacity so bulk RW cannot starve credit/shutdown. */
	uint_t limit = header->op == OV_VSOCK_RW ?
	    device->ntx - MIN(8U, device->ntx / 2U) : device->ntx;
	for (uint_t n = 0; n < limit; n++) {
		if (!device->tx[n].busy) {
			slot = &device->tx[n];
			break;
		}
	}
	if (slot == NULL) {
		error = EAGAIN;
		goto out;
	}
	bcopy(encoded, virtio_dma_va(slot->dma, 0), sizeof (encoded));
	if (header->len != 0)
		bcopy(payload, virtio_dma_va(slot->dma, sizeof (encoded)), header->len);
	virtio_chain_clear(slot->chain);
	if (virtio_chain_append(slot->chain, virtio_dma_cookie_pa(slot->dma, 0),
	    OV_VSOCK_HEADER_BYTES + header->len, VIRTIO_DIR_DEVICE_READS) !=
	    DDI_SUCCESS) {
		error = EIO;
		goto out;
	}
	virtio_dma_sync(slot->dma, DDI_DMA_SYNC_FORDEV);
	slot->busy = B_TRUE;
	virtio_chain_submit(slot->chain, B_TRUE);
out:
	mutex_exit(&device->lock);
	return (error);
}

static boolean_t
ov_slot_alloc(struct ov_device *device, struct ov_slot *slot, uint_t queue,
    size_t bytes)
{
	slot->chain = virtio_chain_alloc(device->queue[queue], KM_SLEEP);
	if (slot->chain == NULL)
		return (B_FALSE);
	slot->dma = virtio_dma_alloc(device->vio, bytes, &ov_dma_attr,
	    DDI_DMA_CONSISTENT | (queue == 1 ? DDI_DMA_WRITE : DDI_DMA_READ),
	    KM_SLEEP);
	if (slot->dma == NULL || virtio_dma_ncookies(slot->dma) != 1)
		return (B_FALSE);
	virtio_chain_data_set(slot->chain, slot);
	if (queue != 1) {
		if (virtio_chain_append(slot->chain,
		    virtio_dma_cookie_pa(slot->dma, 0), bytes,
		    VIRTIO_DIR_DEVICE_WRITES) != DDI_SUCCESS)
			return (B_FALSE);
		virtio_dma_sync(slot->dma, DDI_DMA_SYNC_FORDEV);
		slot->busy = B_TRUE;
		virtio_chain_submit(slot->chain, B_FALSE);
	}
	return (B_TRUE);
}

static void
ov_slot_free(struct ov_slot *slot)
{
	if (slot->chain != NULL)
		virtio_chain_free(slot->chain);
	if (slot->dma != NULL)
		virtio_dma_free(slot->dma);
}

static void
ov_repost(struct ov_slot *slot)
{
	virtio_dma_sync(slot->dma, DDI_DMA_SYNC_FORDEV);
	virtio_chain_submit(slot->chain, B_TRUE);
}

static void
ov_worker(void *arg)
{
	struct ov_device *device = arg;
	virtio_chain_t *chain;
	struct ov_slot *slot;
	struct ov_vsock_header header;

	for (;;) {
		boolean_t progress = B_FALSE;
		boolean_t writable = B_FALSE;
		mutex_enter(&device->lock);
		if (device->stopping) {
			device->queued = B_FALSE;
			mutex_exit(&device->lock);
			return;
		}
		if (device->configuration_pending) {
			device->configuration_pending = B_FALSE;
			/* Configuration changes are not a resumable transport event. */
			device->online = B_FALSE;
			device->reset_failed = B_TRUE;
			mutex_exit(&device->lock);
			ov_callback(NULL, NULL, B_TRUE);
			mutex_enter(&device->lock);
			progress = B_TRUE;
		}
		while ((chain = virtio_queue_poll(device->queue[1])) != NULL) {
			slot = virtio_chain_data(chain);
			slot->busy = B_FALSE;
			writable = progress = B_TRUE;
		}
		if ((chain = virtio_queue_poll(device->queue[2])) != NULL) {
			slot = virtio_chain_data(chain);
			virtio_dma_sync(slot->dma, DDI_DMA_SYNC_FORCPU);
			/* Only the defined transport-reset event may preserve listeners. */
			device->online = !device->reset_failed &&
			    virtio_chain_received_length(chain) ==
			    sizeof (uint32_t) &&
			    *(uint32_t *)virtio_dma_va(slot->dma, 0) == 0 &&
			    virtio_dev_get64(device->vio, 0) == OV_VSOCK_GUEST_CID;
			device->reset_failed = !device->online;
			mutex_exit(&device->lock);
			ov_callback(NULL, NULL, B_TRUE);
			mutex_enter(&device->lock);
			ov_repost(slot);
			progress = B_TRUE;
		}
		chain = virtio_queue_poll(device->queue[0]);
		if (chain != NULL) {
			slot = virtio_chain_data(chain);
			size_t used = virtio_chain_received_length(chain);
			virtio_dma_sync(slot->dma, DDI_DMA_SYNC_FORCPU);
			boolean_t valid = device->online && used <= OV_FRAME &&
			    ov_vsock_decode(virtio_dma_va(slot->dma, 0), used,
			    &header) == OV_VSOCK_OK;
			mutex_exit(&device->lock);
			if (valid)
				ov_callback(&header, virtio_dma_va(slot->dma,
				    OV_VSOCK_HEADER_BYTES), B_FALSE);
			mutex_enter(&device->lock);
			ov_repost(slot);
			progress = B_TRUE;
		}
		if (!progress)
			device->queued = B_FALSE;
		mutex_exit(&device->lock);
		if (writable)
			ov_callback(NULL, NULL, B_FALSE);
		if (!progress)
			return;
	}
}

static uint_t
ov_interrupt(caddr_t arg, caddr_t unused)
{
	struct ov_device *device = (struct ov_device *)arg;
	(void) unused;
	mutex_enter(&device->lock);
	if (!device->stopping && !device->queued) {
		device->queued = B_TRUE;
		/** @cc [owner:ghuntley,label:recovery;security] illumos-guaranteed-interrupt-work
		 * A completion or configuration interrupt MUST queue bounded work without
		 * allocation failure. queued MUST prevent concurrent publication of the
		 * preallocated entry; the taskq returns entry ownership before ov_worker.
		 */
		taskq_dispatch_ent(device->taskq, ov_worker, device, 0,
		    &device->work_entry);
	}
	mutex_exit(&device->lock);
	return (DDI_INTR_CLAIMED);
}

static uint_t
ov_configuration_changed(caddr_t arg, caddr_t unused)
{
	struct ov_device *device = (struct ov_device *)arg;
	mutex_enter(&device->lock);
	device->configuration_pending = B_TRUE;
	device->online = B_FALSE;
	mutex_exit(&device->lock);
	return (ov_interrupt(arg, unused));
}

static void
ov_destroy(struct ov_device *device)
{
	/* An activated device has the static lifetime described by ov_detach(). */
	VERIFY(!device->activated);
	if (device->initialized) {
		virtio_interrupts_disable(device->vio);
		mutex_enter(&device->lock);
		device->stopping = B_TRUE;
		mutex_exit(&device->lock);
	}
	if (device->taskq != NULL) {
		taskq_wait(device->taskq);
		taskq_destroy(device->taskq);
	}
	if (device->vio != NULL) {
		virtio_shutdown(device->vio);
		for (uint_t n = 0; n < 3; n++) {
			if (device->queue[n] != NULL)
				while (virtio_queue_evacuate(device->queue[n]) != NULL)
					;
		}
		for (uint_t n = 0; n < OV_SLOTS; n++) {
			ov_slot_free(&device->rx[n]);
			ov_slot_free(&device->tx[n]);
		}
		ov_slot_free(&device->event);
		virtio_fini(device->vio, B_FALSE);
	}
	if (device->initialized)
		mutex_destroy(&device->lock);
	kmem_free(device, sizeof (*device));
}

/** @cc [owner:ghuntley,label:security;recovery] illumos-activated-failure-retention
 * An unavoidable failure after DRIVER_OK MUST retain every interrupt-visible
 * object and DMA buffer until VM disposal. Remove readiness before draining
 * workers and fence sockets; attach succeeds only as an unavailable, pinned
 * device. A VMM that refuses reset cannot establish safe DMA reclamation.
 */
static void
ov_retain_fenced(struct ov_device *device)
{
	mutex_enter(&ov_global_lock);
	if (ov_device == device)
		ov_device = NULL;
	mutex_exit(&ov_global_lock);
	virtio_interrupts_disable(device->vio);
	mutex_enter(&device->lock);
	device->online = B_FALSE;
	device->stopping = B_TRUE;
	mutex_exit(&device->lock);
	taskq_wait(device->taskq);
	ddi_set_driver_private(device->dip, device);
	ov_callback(NULL, NULL, B_TRUE);
}

static int
ov_attach(dev_info_t *dip, ddi_attach_cmd_t command)
{
	struct ov_device *device;
	if (command != DDI_ATTACH)
		return (DDI_FAILURE);
	device = kmem_zalloc(sizeof (*device), KM_SLEEP);
	device->dip = dip;
	device->vio = virtio_init(dip);
	if (device->vio == NULL ||
	    !virtio_init_features(device->vio, 0, B_FALSE) ||
	    virtio_dev_get64(device->vio, 0) != OV_VSOCK_GUEST_CID)
		goto fail;
	for (uint_t n = 0; n < 3; n++) {
		device->queue[n] = virtio_queue_alloc(device->vio, n,
		    n == 0 ? "receive" : n == 1 ? "transmit" : "event",
		    ov_interrupt, device, B_FALSE, 1);
		if (device->queue[n] == NULL)
			goto fail;
	}
	virtio_register_cfgchange_handler(device->vio, ov_configuration_changed,
	    device);
	/* Allocate fallible resources before init_complete publishes DRIVER_OK. */
	device->taskq = taskq_create("viosock", 1, minclsyspri, 2, 2,
	    TASKQ_PREPOPULATE);
	if (device->taskq == NULL)
		goto fail;
	device->nrx = MIN(OV_SLOTS, virtio_queue_size(device->queue[0]));
	device->ntx = MIN(OV_SLOTS, virtio_queue_size(device->queue[1]));
	for (uint_t n = 0; n < device->nrx; n++)
		if (!ov_slot_alloc(device, &device->rx[n], 0, OV_FRAME))
			goto fail;
	for (uint_t n = 0; n < device->ntx; n++)
		if (!ov_slot_alloc(device, &device->tx[n], 1, OV_FRAME))
			goto fail;
	if (!ov_slot_alloc(device, &device->event, 2, sizeof (uint32_t)))
		goto fail;
	if (virtio_init_complete(device->vio, VIRTIO_ANY_INTR_TYPE) != DDI_SUCCESS)
		goto fail;
	device->activated = B_TRUE;
	mutex_init(&device->lock, NULL, MUTEX_DRIVER, virtio_intr_pri(device->vio));
	device->initialized = B_TRUE;
	virtio_queue_flush(device->queue[0]);
	virtio_queue_flush(device->queue[2]);
	mutex_enter(&ov_global_lock);
	if (ov_device != NULL) {
		mutex_exit(&ov_global_lock);
		goto fail;
	}
	ov_device = device;
	ddi_set_driver_private(dip, device);
	mutex_exit(&ov_global_lock);
	if (virtio_interrupts_enable(device->vio) != DDI_SUCCESS) {
		goto fail;
	}
	mutex_enter(&device->lock);
	device->online = !device->configuration_pending;
	mutex_exit(&device->lock);
	(void) ov_interrupt((caddr_t)device, NULL);
	ddi_report_dev(dip);
	return (DDI_SUCCESS);
fail:
	if (device->activated) {
		ov_retain_fenced(device);
		return (DDI_SUCCESS);
	}
	ov_destroy(device);
	return (DDI_FAILURE);
}

/** @cc [owner:ghuntley,label:security;recovery] illumos-static-device-lifetime
 * Runtime detach MUST refuse for an attached transport. Firecracker does not
 * implement vsock device reset, so status zero does not stop backend DMA.
 * Retain queues, interrupt targets, workers and buffers until VM disposal;
 * reset events fence socket state without reclaiming these objects.
 */
static int
ov_detach(dev_info_t *dip, ddi_detach_cmd_t command)
{
	(void) dip;
	(void) command;
	return (DDI_FAILURE);
}

static int
ov_quiesce(dev_info_t *dip)
{
	struct ov_device *device = ddi_get_driver_private(dip);
	return (virtio_quiesce(device->vio));
}

int
_init(void)
{
	int error;
	mutex_init(&ov_global_lock, NULL, MUTEX_DRIVER, NULL);
	cv_init(&ov_callback_cv, NULL, CV_DRIVER, NULL);
	error = mod_install(&ov_modlinkage);
	if (error != 0) {
		cv_destroy(&ov_callback_cv);
		mutex_destroy(&ov_global_lock);
	}
	return (error);
}

int
_fini(void)
{
	int error = mod_remove(&ov_modlinkage);
	if (error == 0) {
		cv_destroy(&ov_callback_cv);
		mutex_destroy(&ov_global_lock);
	}
	return (error);
}

int
_info(struct modinfo *info)
{
	return (mod_info(&ov_modlinkage, info));
}

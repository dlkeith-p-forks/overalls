/* SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Overalls contributors.
 */
#ifndef _OVERALLS_ILLUMOS_VIOSOCK_H
#define _OVERALLS_ILLUMOS_VIOSOCK_H
#include <sys/types.h>
#include <sys/vsock.h>
#include "ov_vsock.h"

#define OV_ILLUMOS_AF_VSOCK AF_VSOCK
#define OV_ILLUMOS_MAX_SOCKETS 128U
#define OV_ILLUMOS_WINDOW 65536U

#ifndef OV_VSOCK_BUILD_ID
#error "The build must bind the transport to its immutable input identity"
#endif
_Static_assert(sizeof (OV_VSOCK_BUILD_ID) == VSOCK_BUILD_ID_SIZE,
    "transport build identity must contain exactly 64 hex bytes and NUL");

_Static_assert(sizeof (struct sockaddr_vm) == 16,
    "illumos vsock address size");
_Static_assert(__builtin_offsetof(struct sockaddr_vm, svm_port) == 4,
    "illumos vsock port offset");
_Static_assert(__builtin_offsetof(struct sockaddr_vm, svm_cid) == 8,
    "illumos vsock CID offset");

typedef void (*viosock_receive_f)(void *, const struct ov_vsock_header *,
    const uint8_t *);
typedef void (*viosock_notify_f)(void *);

/** @cc [owner:ghuntley,label:security;recovery] illumos-viosock-callback-lifetime
 * Callbacks run in sleepable thread context without transport locks. Unsubscribe MUST
 * prevent new callbacks and wait for in-flight callbacks before returning.
 * Receive payload memory is borrowed only until the callback returns.
 */
int viosock_subscribe(viosock_receive_f, viosock_notify_f,
    viosock_notify_f, void *);
void viosock_unsubscribe(void *);
boolean_t viosock_ready(void);
const char *viosock_build_id(void);

/** @cc [owner:ghuntley,label:security;protocol] illumos-viosock-bounded-transmit
 * Transmit MUST validate the guest-to-host header, copy at most MAX_PAYLOAD
 * bytes into one bounded DMA slot and return EAGAIN when all slots are busy.
 * It MUST NOT retain the caller's header or payload pointers.
 */
int viosock_xmit(const struct ov_vsock_header *, const void *);
#endif

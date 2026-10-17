/* SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Overalls contributors.
 */
#ifndef _SYS_VSOCK_H
#define _SYS_VSOCK_H

#include <sys/types.h>
#include <sys/socket.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Private Overalls illumos ABI; AF 40 is unused by the pinned OmniOS source. */
#define AF_VSOCK 40
#define PF_VSOCK AF_VSOCK
#define VSOCK_SO_BUILD_ID 1
#define VSOCK_BUILD_ID_SIZE 65U
#define VMADDR_CID_ANY ((uint32_t)0xffffffffU)
#define VMADDR_CID_HYPERVISOR ((uint32_t)0U)
#define VMADDR_CID_LOCAL ((uint32_t)1U)
#define VMADDR_CID_HOST ((uint32_t)2U)
#define VMADDR_PORT_ANY ((uint32_t)0xffffffffU)

/** @cc [owner:ghuntley,label:protocol;security] illumos-vsock-public-address
 * The public address MUST remain 16 bytes: family16, zero reserved16, port32,
 * CID32 and four zero bytes, in native byte order. Only STREAM/protocol zero,
 * guest CID 3/ANY binding and host CID 2 incoming connections are supported.
 * VMADDR_PORT_ANY requests a bounded ephemeral nonzero port; port zero is invalid.
 */
struct sockaddr_vm {
	sa_family_t svm_family;
	uint16_t svm_reserved;
	uint32_t svm_port;
	uint32_t svm_cid;
	uint8_t svm_zero[4];
};

#ifdef __cplusplus
}
#endif
#endif

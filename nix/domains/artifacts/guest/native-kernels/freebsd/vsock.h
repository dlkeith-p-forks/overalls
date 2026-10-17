/* SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Overalls contributors.
 */
#ifndef _SYS_OVERALLS_VSOCK_H_
#define _SYS_OVERALLS_VSOCK_H_

#include <sys/types.h>
#include <sys/stdint.h>
#include <sys/socket.h>

#ifdef AF_VSOCK
#if AF_VSOCK != AF_VENDOR03
#error "FreeBSD Overalls vsock requires vendor family 45"
#endif
#else
#define AF_VSOCK AF_VENDOR03
#endif

#define VMADDR_CID_ANY UINT32_MAX
#define VMADDR_CID_HOST 2U
#define VMADDR_CID_GUEST 3U
#define VMADDR_PORT_ANY UINT32_MAX
#define VSOCK_SO_BUILD_ID 1
#define VSOCK_BUILD_ID_SIZE 65U

/** @cc [owner:ghuntley,label:protocol] freebsd-public-vsock-abi
 * Native callers MUST use the FreeBSD length/family prefix and host-order port
 * and CID fields. The complete address is 16 bytes with port at 4 and CID at 8.
 */
struct sockaddr_vm {
    uint8_t svm_len;
    sa_family_t svm_family;
    uint16_t svm_reserved;
    uint32_t svm_port;
    uint32_t svm_cid;
    uint8_t svm_zero[4];
};

_Static_assert(AF_VSOCK == 45, "FreeBSD vsock vendor family");
_Static_assert(sizeof(sa_family_t) == 1, "FreeBSD vsock family width");
_Static_assert(sizeof(struct sockaddr_vm) == 16, "FreeBSD vsock address size");
_Static_assert(__builtin_offsetof(struct sockaddr_vm, svm_port) == 4,
    "FreeBSD vsock port offset");
_Static_assert(__builtin_offsetof(struct sockaddr_vm, svm_cid) == 8,
    "FreeBSD vsock CID offset");
#endif

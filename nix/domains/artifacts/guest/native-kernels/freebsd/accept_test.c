/* SPDX-License-Identifier: BSD-2-Clause */
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include "ov_vsock.h"

#define OVFB_WINDOW 65536U
#define OVFB_SOCKETS 128U

struct socket;
struct ovfb_pcb {
    struct socket *so;
    struct ov_vsock_connection connection;
    uint32_t local_port, peer_port;
    bool bound, connected;
};
struct socket {
    struct ovfb_pcb *so_pcb;
    unsigned references;
    bool queued, connected;
};

static bool fail_clone, fail_control;
static unsigned sockets, pcbs, refused, publications;
static struct socket *published;

static struct socket *
solisten_clone(struct socket *head)
{
    struct socket *so;

    assert(head != NULL);
    if (fail_clone)
        return NULL;
    so = calloc(1, sizeof(*so));
    assert(so != NULL);
    sockets++;
    return so;
}

static int
ovfb_attach_socket(struct socket *so, int protocol, void *thread)
{
    assert(protocol == 0 && thread == NULL && so->so_pcb == NULL);
    if (pcbs == OVFB_SOCKETS)
        return 1;
    so->so_pcb = calloc(1, sizeof(*so->so_pcb));
    assert(so->so_pcb != NULL);
    so->so_pcb->so = so;
    pcbs++;
    return 0;
}

static void
ovfb_detach_socket(struct socket *so)
{
    assert(so->so_pcb != NULL && pcbs != 0);
    free(so->so_pcb);
    so->so_pcb = NULL;
    pcbs--;
}

static void
sodealloc(struct socket *so)
{
    assert(!so->queued && so->references == 0 && so->so_pcb == NULL);
    assert(sockets != 0);
    free(so);
    sockets--;
}

static int
ovfb_control(struct ovfb_pcb *pcb, uint16_t op, uint32_t flags)
{
    assert(!pcb->so->queued && pcb->so->references == 0);
    assert(op == OV_VSOCK_RESPONSE && flags == 0);
    assert(pcb->connection.phase == OV_VSOCK_ESTABLISHED);
    return fail_control ? 1 : 0;
}

static void
ovfb_refuse(const struct ov_vsock_header *header)
{
    assert(header != NULL);
    refused++;
}

static bool
solisten_enqueue(struct socket *so, int status)
{
    assert(status == 0 && !so->queued && so->references == 0);
    assert(so->so_pcb != NULL && so->so_pcb->connected);
    so->references = 1;
    so->queued = true;
    published = so;
    publications++;
    return false;
}

static void
soisconnected(struct socket *so)
{
    assert(so->queued && so->references == 1);
    so->connected = true;
}

#include "ovfb_accept.h"

/** @cc [owner:ghuntley,label:verification] freebsd-accept-lifetime-regression
 * The actual accept helper and shared core MUST reject invalid counters before
 * allocation, release unpublished children on allocation/control exhaustion,
 * and publish valid children only after successful RESPONSE enqueue. These
 * mocked socket checks MUST NOT be represented as native kernel execution.
 */
int
main(void)
{
    struct socket head = {0};
    struct ovfb_pcb listener = { .so = &head };
    struct ov_vsock_header request = {
        .src_cid = OV_VSOCK_HOST_CID, .dst_cid = OV_VSOCK_GUEST_CID,
        .src_port = 1000, .dst_port = 1001, .type = 1,
        .op = OV_VSOCK_REQUEST, .buf_alloc = OVFB_WINDOW
    };
    unsigned i;

    request.fwd_cnt = 1;
    for (i = 0; i < 10000; i++)
        ovfb_new_connection(&request, &listener);
    assert(refused == 10000 && sockets == 0 && pcbs == 0);
    assert(publications == 0);
    request.fwd_cnt = 0;
    fail_clone = true;
    ovfb_new_connection(&request, &listener);
    fail_clone = false;
    assert(sockets == 0 && pcbs == 0 && publications == 0);
    pcbs = OVFB_SOCKETS;
    ovfb_new_connection(&request, &listener);
    assert(sockets == 0 && pcbs == OVFB_SOCKETS && publications == 0);
    pcbs = 0;
    fail_control = true;
    for (i = 0; i < 10000; i++)
        ovfb_new_connection(&request, &listener);
    fail_control = false;
    assert(sockets == 0 && pcbs == 0 && publications == 0);
    assert(refused == 20002);
    ovfb_new_connection(&request, &listener);
    assert(sockets == 1 && pcbs == 1 && publications == 1);
    assert(published != NULL && published->connected);
    assert(published->so_pcb->connection.peer_buf_alloc == OVFB_WINDOW);
    published->queued = false;
    published->references = 0;
    ovfb_detach_socket(published);
    sodealloc(published);
    assert(sockets == 0 && pcbs == 0);
    return 0;
}

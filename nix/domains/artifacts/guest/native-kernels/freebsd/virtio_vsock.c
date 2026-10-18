/*-
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Geoffrey Huntley
 *
 * Overalls host-only virtio-vsock stream transport. The OS-independent wire
 * parser and credit state machine live in ov_vsock.{h,c}.
 */
#include <sys/param.h>
#include <sys/bus.h>
#include <sys/domain.h>
#include <sys/endian.h>
#include <sys/kernel.h>
#include <sys/lock.h>
#include <sys/malloc.h>
#include <sys/mbuf.h>
#include <sys/module.h>
#include <sys/mutex.h>
#include <sys/protosw.h>
#include <sys/priv.h>
#include <sys/queue.h>
#include <sys/sglist.h>
#include <sys/socket.h>
#include <sys/sockopt.h>
#include <sys/vsock.h>
#include <sys/socketvar.h>
#include <sys/sockbuf.h>
#include <sys/sx.h>
#include <sys/systm.h>
#include <sys/sysctl.h>
#include <sys/taskqueue.h>
#include <machine/bus.h>
#include <dev/virtio/virtio.h>
#include <dev/virtio/virtqueue.h>
#include <dev/virtio/virtio_ring.h>
#include "virtio_if.h"
#include "ov_vsock.h"
#include "overalls_vsock_build.h"

#define OVFB_WINDOW 65536U
#define OVFB_FRAME (44U + OVFB_WINDOW)
#define OVFB_BUFFERS 32U
#define OVFB_SEGMENTS 32
#define OVFB_SOCKETS 128U
#define OVFB_PORT_ANY UINT32_MAX
#define OVFB_CID_ANY UINT32_MAX
CTASSERT(sizeof(OV_VSOCK_BUILD_ID) == VSOCK_BUILD_ID_SIZE);

/** @cc [owner:ghuntley,label:verification] booted-vsock-build-identity
 * These read-only OIDs MUST identify the compiled source/patch/configuration/
 * compiler inputs independently of the kernel file currently on disk. They
 * are guest-reported identity evidence, not cryptographic attestation.
 */
SYSCTL_STRING(_kern, OID_AUTO, overalls_vsock_build_id, CTLFLAG_RD,
    __DECONST(char *, OV_VSOCK_BUILD_ID), 0,
    "Overalls host-only vsock build input identity");
SYSCTL_UINT(_kern, OID_AUTO, overalls_vsock_abi, CTLFLAG_RD, SYSCTL_NULL_UINT_PTR, 1,
    "Overalls host-only vsock domain ABI version");
SYSCTL_UINT(_kern, OID_AUTO, overalls_vsock_cid, CTLFLAG_RD, SYSCTL_NULL_UINT_PTR,
    OV_VSOCK_GUEST_CID, "Overalls host-only vsock guest CID");

MALLOC_DEFINE(M_OVSOCK, "overalls_vsock", "bounded host-only vsock state");

struct ovfb_packet {
    struct sglist *sg;
    uint8_t *data;
    bool busy;
};
struct ovfb_softc {
    device_t dev;
    struct mtx lock;
    struct virtqueue *rx, *tx, *event;
    struct task work;
    struct ovfb_packet rxbuf[OVFB_BUFFERS], txbuf[OVFB_BUFFERS];
    struct sglist *event_sg;
    uint32_t event_data;
    bool ready, stopping, reset_pending, queues_ready, interrupts_ready;
};
struct ovfb_pcb {
    LIST_ENTRY(ovfb_pcb) link;
    struct socket *so;
    struct ov_vsock_connection connection;
    uint32_t local_port, peer_port;
    uint32_t received, consumed;
    bool bound, listening, connected, fenced;
    bool credit_pending, credit_requested, shutdown_pending;
    bool receive_shutdown_pending;
};
static LIST_HEAD(, ovfb_pcb) ovfb_pcbs = LIST_HEAD_INITIALIZER(ovfb_pcbs);
static struct sx ovfb_domain_lock;
/* PCI device attach precedes protocol-domain initialization. */
SX_SYSINIT_FLAGS(ovfb_domain_lock, &ovfb_domain_lock,
    "overalls_vsock_domain", SX_RECURSE);
static struct ovfb_softc *ovfb_device;
static unsigned ovfb_socket_count;
static uint32_t ovfb_ephemeral = 49152;

static int ovfb_attach_socket(struct socket *, int, struct thread *);
static void ovfb_detach_socket(struct socket *);
static int ovfb_bind(struct socket *, struct sockaddr *, struct thread *);
static int ovfb_listen(struct socket *, int, struct thread *);
static int ovfb_accept(struct socket *, struct sockaddr **);
static int ovfb_connect(struct socket *, struct sockaddr *, struct thread *);
static int ovfb_disconnect(struct socket *);
static void ovfb_close(struct socket *);
static int ovfb_shutdown(struct socket *);
static int ovfb_flush_socket(struct socket *, int);
static int ovfb_send(struct socket *, int, struct mbuf *, struct sockaddr *,
    struct mbuf *, struct thread *);
static int ovfb_rcvd(struct socket *, int);
static int ovfb_peeraddr(struct socket *, struct sockaddr **);
static int ovfb_sockaddr(struct socket *, struct sockaddr **);
static int ovfb_ctloutput(struct socket *, struct sockopt *);
static int ovfb_setsbopt(struct socket *, struct sockopt *);
static void ovfb_work(void *, int);
static void ovfb_interrupt(void *);
static void ovfb_flush(struct ovfb_pcb *);
static int ovfb_control(struct ovfb_pcb *, uint16_t, uint32_t);
static int ovfb_detach(device_t);

static struct protosw ovfb_protosw = {
    .pr_type = SOCK_STREAM,
    .pr_protocol = 0,
    .pr_flags = PR_CONNREQUIRED | PR_WANTRCVD,
    .pr_attach = ovfb_attach_socket,
    .pr_detach = ovfb_detach_socket,
    .pr_bind = ovfb_bind,
    .pr_listen = ovfb_listen,
    .pr_accept = ovfb_accept,
    .pr_connect = ovfb_connect,
    .pr_disconnect = ovfb_disconnect,
    .pr_close = ovfb_close,
    .pr_abort = ovfb_close,
    .pr_shutdown = ovfb_shutdown,
    .pr_flush = ovfb_flush_socket,
    .pr_send = ovfb_send,
    .pr_rcvd = ovfb_rcvd,
    .pr_peeraddr = ovfb_peeraddr,
    .pr_sockaddr = ovfb_sockaddr,
    .pr_ctloutput = ovfb_ctloutput,
    .pr_setsbopt = ovfb_setsbopt,
    .pr_sosend = sosend_generic,
    .pr_soreceive = soreceive_generic,
};
static struct domain ovfb_domain = {
    .dom_family = AF_VSOCK,
    .dom_name = "overalls_vsock",
    .dom_nprotosw = 1,
    .dom_protosw = { &ovfb_protosw },
};
DOMAIN_SET(ovfb_);

/** @cc [owner:ghuntley,label:security] freebsd-immutable-socket-buffers
 * SO_SNDBUF, SO_RCVBUF and their low-water options MUST refuse modification.
 * The protocol hook MUST prevent the native default from enlarging the fixed
 * 64 KiB send/receive bounds or suppressing wakeups beyond their capacity.
 */
static int
ovfb_setsbopt(struct socket *so, struct sockopt *sopt)
{
    return (EOPNOTSUPP);
}

/** @cc [owner:ghuntley,label:verification;security] freebsd-runtime-build-option
 * Only a live, unfenced socket MAY return the immutable compiled build ID.
 * Option 1 at AF_VSOCK MUST return all 64 lowercase hex bytes plus NUL, reject
 * short buffers, and refuse sets. It does not attest an untrusted guest.
 */
static int
ovfb_ctloutput(struct socket *so, struct sockopt *sopt)
{
    struct ovfb_pcb *pcb;
    int error;

    if (sopt->sopt_level != AF_VSOCK ||
        sopt->sopt_name != VSOCK_SO_BUILD_ID)
        return (ENOPROTOOPT);
    if (sopt->sopt_dir != SOPT_GET)
        return (EOPNOTSUPP);
    if (sopt->sopt_valsize < VSOCK_BUILD_ID_SIZE)
        return (EMSGSIZE);
    sx_xlock(&ovfb_domain_lock);
    pcb = so->so_pcb;
    error = pcb == NULL || pcb->fenced || ovfb_device == NULL ||
        !ovfb_device->ready ? ECONNRESET : 0;
    if (error == 0)
        error = sooptcopyout(sopt, OV_VSOCK_BUILD_ID, VSOCK_BUILD_ID_SIZE);
    sx_xunlock(&ovfb_domain_lock);
    return (error);
}

/** @cc [owner:ghuntley,label:security] bounded-socket-allocation
 * At most 128 privileged socket control blocks exist, including incomplete
 * accepts whose credentials are inherited from the privileged listener.
 * Unprivileged socket creation MUST NOT exhaust the fixed agent socket pool.
 */
static int
ovfb_attach_socket(struct socket *so, int protocol, struct thread *td)
{
    struct ovfb_pcb *pcb;
    int error;

    if (so->so_type != SOCK_STREAM || protocol != 0)
        return (EPROTONOSUPPORT);
    error = priv_check_cred(so->so_cred, PRIV_NETINET_RESERVEDPORT);
    if (error != 0)
        return (error);
    sx_xlock(&ovfb_domain_lock);
    if (ovfb_device == NULL || !ovfb_device->ready) {
        sx_xunlock(&ovfb_domain_lock);
        return (ENXIO);
    }
    if (ovfb_socket_count >= OVFB_SOCKETS) {
        sx_xunlock(&ovfb_domain_lock);
        return (ENOBUFS);
    }
    pcb = malloc(sizeof(*pcb), M_OVSOCK, M_NOWAIT | M_ZERO);
    if (pcb == NULL) {
        sx_xunlock(&ovfb_domain_lock);
        return (ENOMEM);
    }
    error = soreserve(so, OVFB_WINDOW, OVFB_WINDOW);
    if (error != 0) {
        free(pcb, M_OVSOCK);
        sx_xunlock(&ovfb_domain_lock);
        return (error);
    }
    pcb->so = so;
    so->so_pcb = pcb;
    LIST_INSERT_HEAD(&ovfb_pcbs, pcb, link);
    ovfb_socket_count++;
    sx_xunlock(&ovfb_domain_lock);
    return (0);
}

static void
ovfb_detach_socket(struct socket *so)
{
    struct ovfb_pcb *pcb;

    sx_xlock(&ovfb_domain_lock);
    pcb = so->so_pcb;
    if (pcb != NULL) {
        LIST_REMOVE(pcb, link);
        ovfb_socket_count--;
        so->so_pcb = NULL;
        explicit_bzero(pcb, sizeof(*pcb));
        free(pcb, M_OVSOCK);
    }
    sx_xunlock(&ovfb_domain_lock);
}

static bool
ovfb_port_used(uint32_t port)
{
    struct ovfb_pcb *pcb;

    LIST_FOREACH(pcb, &ovfb_pcbs, link)
        if (pcb->bound && !pcb->connected && pcb->local_port == port)
            return (true);
    return (false);
}

static int
ovfb_bind(struct socket *so, struct sockaddr *address, struct thread *td)
{
    const struct sockaddr_vm *vm;
    struct ovfb_pcb *pcb;
    uint32_t port;
    unsigned attempt;
    int error;

    if (td == NULL)
        return (EPERM);
    error = priv_check(td, PRIV_NETINET_RESERVEDPORT);
    if (error != 0)
        return (error);
    if (address == NULL || address->sa_len != sizeof(*vm))
        return (EINVAL);
    vm = (const struct sockaddr_vm *)address;
    if (vm->svm_family != AF_VSOCK)
        return (EAFNOSUPPORT);
    if ((vm->svm_cid != 3 && vm->svm_cid != OVFB_CID_ANY) ||
        vm->svm_reserved != 0 ||
        memcmp(vm->svm_zero, "\0\0\0\0", sizeof(vm->svm_zero)) != 0)
        return (EINVAL);
    sx_xlock(&ovfb_domain_lock);
    pcb = so->so_pcb;
    error = 0;
    if (pcb == NULL || pcb->bound || pcb->fenced) {
        error = EINVAL;
        goto out;
    }
    port = vm->svm_port;
    if (port == OVFB_PORT_ANY) {
        for (attempt = 0; attempt < OVFB_SOCKETS + 1; attempt++) {
            port = ovfb_ephemeral++;
            if (ovfb_ephemeral == OVFB_PORT_ANY)
                ovfb_ephemeral = 49152;
            if (!ovfb_port_used(port))
                break;
        }
    }
    if (port == 0 || ovfb_port_used(port)) {
        error = EADDRINUSE;
        goto out;
    }
    pcb->local_port = port;
    pcb->bound = true;
out:
    sx_xunlock(&ovfb_domain_lock);
    return (error);
}

static int
ovfb_listen(struct socket *so, int backlog, struct thread *td)
{
    struct ovfb_pcb *pcb;
    int error;

    sx_xlock(&ovfb_domain_lock);
    pcb = so->so_pcb;
    error = EINVAL;
    if (pcb != NULL && pcb->bound && !pcb->connected && !pcb->fenced) {
        SOCK_LOCK(so);
        error = solisten_proto_check(so);
        if (error == 0) {
            solisten_proto(so, MIN(backlog, 32));
            pcb->listening = true;
        }
        SOCK_UNLOCK(so);
    }
    sx_xunlock(&ovfb_domain_lock);
    return (error);
}

static int
ovfb_address(struct socket *so, struct sockaddr **out, bool peer)
{
    struct sockaddr_vm address;
    struct ovfb_pcb *pcb;
    int error;

    sx_xlock(&ovfb_domain_lock);
    pcb = so->so_pcb;
    error = ENOTCONN;
    if (pcb != NULL && (!peer || pcb->connected)) {
        bzero(&address, sizeof(address));
        address.svm_len = sizeof(address);
        address.svm_family = AF_VSOCK;
        address.svm_port = peer ? pcb->peer_port : pcb->local_port;
        address.svm_cid = peer ? 2 : 3;
        *out = sodupsockaddr((const struct sockaddr *)&address, M_NOWAIT);
        error = *out == NULL ? ENOMEM : 0;
    }
    sx_xunlock(&ovfb_domain_lock);
    return (error);
}

static int ovfb_accept(struct socket *so, struct sockaddr **out)
{ return (ovfb_address(so, out, true)); }
static int ovfb_peeraddr(struct socket *so, struct sockaddr **out)
{ return (ovfb_address(so, out, true)); }
static int ovfb_sockaddr(struct socket *so, struct sockaddr **out)
{ return (ovfb_address(so, out, false)); }

/* Guest agents are passive listeners. Outbound streams need separate evidence. */
static int
ovfb_connect(struct socket *so, struct sockaddr *address, struct thread *td)
{
    return (EOPNOTSUPP);
}

/* Caller holds the domain lock; queue lock never encloses a socket operation. */
static struct ovfb_packet *
ovfb_tx_acquire(struct ovfb_softc *sc, bool control)
{
    unsigned i;

    /* Eight descriptors remain available for credit, reset and shutdown. */
    for (i = 0; i < (control ? OVFB_BUFFERS : OVFB_BUFFERS - 8); i++) {
        if (!sc->txbuf[i].busy) {
            sc->txbuf[i].busy = true;
            return (&sc->txbuf[i]);
        }
    }
    return (NULL);
}

static int
ovfb_enqueue(struct ovfb_softc *sc, struct ovfb_packet *packet, size_t length)
{
    int error;

    sglist_reset(packet->sg);
    error = sglist_append(packet->sg, packet->data, length);
    if (error == 0) {
        mtx_lock(&sc->lock);
        error = sc->ready ? virtqueue_enqueue(sc->tx, packet, packet->sg,
            packet->sg->sg_nseg, 0) : ENXIO;
        if (error == 0)
            virtqueue_notify(sc->tx);
        mtx_unlock(&sc->lock);
    }
    if (error != 0)
        packet->busy = false;
    return (error);
}

static void
ovfb_header(struct ovfb_pcb *pcb, struct ov_vsock_header *header,
    uint16_t operation, uint32_t length, uint32_t flags)
{
    bzero(header, sizeof(*header));
    header->src_cid = 3;
    header->dst_cid = 2;
    header->src_port = pcb->local_port;
    header->dst_port = pcb->peer_port;
    header->len = length;
    header->type = 1;
    header->op = operation;
    header->flags = flags;
    header->buf_alloc =
        (pcb->connection.local_shutdown & OV_VSOCK_SHUTDOWN_RECEIVE) != 0 ?
        0 : OVFB_WINDOW;
    header->fwd_cnt = pcb->consumed;
}

static int
ovfb_control(struct ovfb_pcb *pcb, uint16_t operation, uint32_t flags)
{
    struct ov_vsock_header header;
    struct ovfb_packet *packet;
    struct ovfb_softc *sc;
    int error;

    sc = ovfb_device;
    if (sc == NULL || !sc->ready)
        return (ENXIO);
    packet = ovfb_tx_acquire(sc, true);
    if (packet == NULL)
        return (ENOBUFS);
    ovfb_header(pcb, &header, operation, 0, flags);
    error = ov_vsock_encode(packet->data, OVFB_FRAME, &header);
    if (error != 0) {
        packet->busy = false;
        return (EINVAL);
    }
    return (ovfb_enqueue(sc, packet, 44));
}

static void
ovfb_flush(struct ovfb_pcb *pcb)
{
    struct ovfb_softc *sc;
    struct ovfb_packet *packet;
    struct ov_vsock_header header;
    struct socket *so;
    uint32_t credit, length;
    int error;

    sc = ovfb_device;
    so = pcb->so;
    if (!pcb->connected || sc == NULL || !sc->ready)
        return;
    if (ov_vsock_tx_credit(&pcb->connection) != 0)
        pcb->credit_requested = false;
    if (pcb->receive_shutdown_pending && ovfb_control(pcb, OV_VSOCK_SHUTDOWN,
        OV_VSOCK_SHUTDOWN_RECEIVE) == 0)
        pcb->receive_shutdown_pending = false;
    while ((credit = ov_vsock_tx_credit(&pcb->connection)) != 0) {
        packet = ovfb_tx_acquire(sc, false);
        if (packet == NULL)
            break;
        SOCK_SENDBUF_LOCK(so);
        length = MIN((uint32_t)sbavail(&so->so_snd), MIN(credit, OVFB_WINDOW));
        if (length == 0) {
            SOCK_SENDBUF_UNLOCK(so);
            packet->busy = false;
            break;
        }
        m_copydata(so->so_snd.sb_mb, 0, length,
            (char *)(packet->data + OV_VSOCK_HEADER_BYTES));
        SOCK_SENDBUF_UNLOCK(so);
        ovfb_header(pcb, &header, OV_VSOCK_RW, length, 0);
        error = ov_vsock_encode(packet->data, OVFB_FRAME, &header);
        if (error != 0) {
            packet->busy = false;
            break;
        }
        error = ovfb_enqueue(sc, packet, 44 + length);
        if (error != 0)
            break;
        (void)ov_vsock_sent(&pcb->connection, length);
        SOCK_SENDBUF_LOCK(so);
        sbdrop_locked(&so->so_snd, length);
        sowwakeup_locked(so);
    }
    /** @cc [owner:ghuntley,label:protocol;recovery] freebsd-credit-request-progress
     * Buffered output blocked on zero peer credit MUST request an update once
     * per blocked interval. Queue exhaustion MUST retain retry eligibility;
     * observing restored credit MUST permit the next bounded request.
     */
    SOCK_SENDBUF_LOCK(so);
    length = sbavail(&so->so_snd);
    SOCK_SENDBUF_UNLOCK(so);
    if (length != 0 && ov_vsock_tx_credit(&pcb->connection) == 0 &&
        !pcb->credit_requested &&
        (pcb->connection.local_shutdown & OV_VSOCK_SHUTDOWN_SEND) == 0 &&
        (pcb->connection.peer_shutdown & OV_VSOCK_SHUTDOWN_RECEIVE) == 0 &&
        ovfb_control(pcb, OV_VSOCK_CREDIT_REQUEST, 0) == 0)
        pcb->credit_requested = true;
    if (pcb->credit_pending && ovfb_control(pcb, OV_VSOCK_CREDIT_UPDATE, 0) == 0)
        pcb->credit_pending = false;
    if (pcb->shutdown_pending) {
        SOCK_SENDBUF_LOCK(so);
        length = sbavail(&so->so_snd);
        SOCK_SENDBUF_UNLOCK(so);
        if (length == 0 && ovfb_control(pcb, OV_VSOCK_SHUTDOWN,
            OV_VSOCK_SHUTDOWN_SEND) == 0) {
            pcb->shutdown_pending = false;
            (void)ov_vsock_shutdown(&pcb->connection,
                OV_VSOCK_SHUTDOWN_SEND);
        }
    }
}

static int
ovfb_send(struct socket *so, int flags, struct mbuf *data,
    struct sockaddr *address, struct mbuf *control, struct thread *td)
{
    struct ovfb_pcb *pcb;
    int error;

    error = 0;
    if (control != NULL || address != NULL || (flags & PRUS_OOB) != 0) {
        m_freem(control);
        m_freem(data);
        return (EOPNOTSUPP);
    }
    sx_xlock(&ovfb_domain_lock);
    pcb = so->so_pcb;
    if (pcb == NULL || !pcb->connected) {
        error = ENOTCONN;
        m_freem(data);
        goto out;
    }
    if (pcb->shutdown_pending ||
        (pcb->connection.local_shutdown & OV_VSOCK_SHUTDOWN_SEND) != 0 ||
        (pcb->connection.peer_shutdown & OV_VSOCK_SHUTDOWN_RECEIVE) != 0) {
        error = EPIPE;
        m_freem(data);
        goto out;
    }
    SOCK_SENDBUF_LOCK(so);
    if (data != NULL)
        sbappendstream_locked(&so->so_snd, data, 0);
    SOCK_SENDBUF_UNLOCK(so);
    ovfb_flush(pcb);
    if ((flags & PRUS_EOF) != 0)
        error = ovfb_shutdown(so);
out:
    sx_xunlock(&ovfb_domain_lock);
    return (error);
}

static int
ovfb_rcvd(struct socket *so, int flags)
{
    struct ovfb_pcb *pcb;
    uint32_t pending, consumed;

    sx_xlock(&ovfb_domain_lock);
    pcb = so->so_pcb;
    if (pcb != NULL && pcb->connected &&
        (pcb->connection.local_shutdown & OV_VSOCK_SHUTDOWN_RECEIVE) == 0) {
        SOCK_RECVBUF_LOCK(so);
        pending = sbavail(&so->so_rcv);
        SOCK_RECVBUF_UNLOCK(so);
        if (pending > pcb->received - pcb->consumed) {
            sx_xunlock(&ovfb_domain_lock);
            return (EINVAL);
        }
        consumed = pcb->received - pcb->consumed - pending;
        if (consumed != 0) {
            (void)ov_vsock_consumed(&pcb->connection, consumed);
            pcb->consumed += consumed;
            pcb->credit_pending = true;
            ovfb_flush(pcb);
        }
    }
    sx_xunlock(&ovfb_domain_lock);
    return (0);
}

static int
ovfb_flush_socket(struct socket *so, int how)
{
    struct ovfb_pcb *pcb;
    uint32_t discarded;

    if (how == SHUT_WR)
        return (0);
    sx_xlock(&ovfb_domain_lock);
    pcb = so->so_pcb;
    if (pcb != NULL && pcb->connected) {
        discarded = pcb->connection.rx_cnt - pcb->connection.rx_fwd_cnt;
        (void)ov_vsock_consumed(&pcb->connection, discarded);
        pcb->consumed = pcb->received;
        (void)ov_vsock_shutdown(&pcb->connection, OV_VSOCK_SHUTDOWN_RECEIVE);
        pcb->receive_shutdown_pending = true;
        pcb->credit_pending = false;
        ovfb_flush(pcb);
    }
    sx_xunlock(&ovfb_domain_lock);
    return (0);
}

static int
ovfb_shutdown(struct socket *so)
{
    struct ovfb_pcb *pcb;
    int error;

    sx_xlock(&ovfb_domain_lock);
    pcb = so->so_pcb;
    error = pcb != NULL && pcb->connected ? 0 : ENOTCONN;
    if (error == 0) {
        pcb->shutdown_pending = true;
        socantsendmore(so);
        ovfb_flush(pcb);
    }
    sx_xunlock(&ovfb_domain_lock);
    return (error);
}

static int
ovfb_disconnect(struct socket *so)
{
    struct ovfb_pcb *pcb;

    sx_xlock(&ovfb_domain_lock);
    pcb = so->so_pcb;
    if (pcb != NULL && pcb->connected) {
        (void)ovfb_control(pcb, OV_VSOCK_RST, 0);
        ov_vsock_reset(&pcb->connection);
        pcb->connected = false;
        soisdisconnected(so);
    }
    sx_xunlock(&ovfb_domain_lock);
    return (0);
}

static void
ovfb_close(struct socket *so)
{
    struct ovfb_pcb *pcb;

    sx_xlock(&ovfb_domain_lock);
    (void)ovfb_disconnect(so);
    pcb = so->so_pcb;
    if (pcb != NULL) {
        pcb->listening = false;
        pcb->bound = false;
        pcb->fenced = true;
        ov_vsock_reset(&pcb->connection);
    }
    sx_xunlock(&ovfb_domain_lock);
}

static struct ovfb_pcb *
ovfb_lookup(const struct ov_vsock_header *header, bool listener)
{
    struct ovfb_pcb *pcb;

    LIST_FOREACH(pcb, &ovfb_pcbs, link) {
        if (pcb->local_port == header->dst_port &&
            (listener ? pcb->listening : (pcb->connected &&
            pcb->peer_port == header->src_port)))
            return (pcb);
    }
    return (NULL);
}

static void
ovfb_refuse(const struct ov_vsock_header *header)
{
    struct ovfb_pcb refused;

    if (header->op == OV_VSOCK_RST)
        return;
    bzero(&refused, sizeof(refused));
    refused.local_port = header->dst_port;
    refused.peer_port = header->src_port;
    (void)ovfb_control(&refused, OV_VSOCK_RST, 0);
}

#include "ovfb_accept.h"

/** @cc [owner:ghuntley,label:security] parse-before-socket-effects
 * Only the common decoder's validated host2/guest3 frames reach socket state.
 * Receive bytes and accepted socket count stay inside fixed resource limits.
 */
static void
ovfb_receive(struct ovfb_packet *packet, uint32_t used)
{
    struct ov_vsock_header header;
    struct ovfb_pcb *pcb, *listener;
    struct socket *so;
    struct mbuf *m;
    enum ov_vsock_action action;

    if (ov_vsock_decode(packet->data, used, &header) != 0)
        return;
    pcb = ovfb_lookup(&header, false);
    if (pcb == NULL && header.op == OV_VSOCK_REQUEST) {
        listener = ovfb_lookup(&header, true);
        if (listener == NULL) {
            ovfb_refuse(&header);
            return;
        }
        ovfb_new_connection(&header, listener);
        return;
    }
    if (pcb == NULL) {
        ovfb_refuse(&header);
        return;
    }
    so = pcb->so;
    action = ov_vsock_receive(&pcb->connection, &header);
    switch (action) {
    case OV_VSOCK_DELIVER_DATA:
        if (header.len == 0)
            break;
        SOCK_RECVBUF_LOCK(so);
        if ((uint32_t)sbspace(&so->so_rcv) < header.len) {
            SOCK_RECVBUF_UNLOCK(so);
            goto reset;
        }
        SOCK_RECVBUF_UNLOCK(so);
        m = m_getm2(NULL, header.len, M_NOWAIT, MT_DATA, 0);
        if (m == NULL)
            goto reset;
        m_copyback(m, 0, header.len,
            (const char *)(packet->data + OV_VSOCK_HEADER_BYTES));
        if (m_length(m, NULL) != header.len) {
            m_freem(m);
            goto reset;
        }
        SOCK_RECVBUF_LOCK(so);
        sbappendstream_locked(&so->so_rcv, m, 0);
        pcb->received += header.len;
        sorwakeup_locked(so);
        break;
    case OV_VSOCK_SEND_CREDIT:
        (void)ovfb_rcvd(so, 0);
        pcb->credit_pending = true;
        break;
    case OV_VSOCK_PEER_SHUTDOWN:
        if ((header.flags & OV_VSOCK_SHUTDOWN_SEND) != 0)
            socantrcvmore(so);
        if ((header.flags & OV_VSOCK_SHUTDOWN_RECEIVE) != 0)
            socantsendmore(so);
        break;
    case OV_VSOCK_CONNECTION_CLOSED:
        pcb->connected = false;
        SOCK_LOCK(so);
        so->so_error = ECONNRESET;
        SOCK_UNLOCK(so);
        soisdisconnected(so);
        break;
    case OV_VSOCK_REFUSED:
        goto reset;
    default:
        break;
    }
    ovfb_flush(pcb);
    return;
reset:
    (void)ovfb_control(pcb, OV_VSOCK_RST, 0);
    ov_vsock_reset(&pcb->connection);
    pcb->connected = false;
    SOCK_LOCK(so);
    so->so_error = ECONNRESET;
    SOCK_UNLOCK(so);
    soisdisconnected(so);
}

static void
ovfb_interrupt(void *argument)
{
    struct ovfb_softc *sc = argument;

    mtx_lock(&sc->lock);
    if (!sc->stopping)
        taskqueue_enqueue(taskqueue_thread, &sc->work);
    mtx_unlock(&sc->lock);
}

/** @cc [owner:ghuntley,label:recovery;security] freebsd-reset-listener-continuation
 * Only a validated transport-reset event with unchanged CID MAY preserve live
 * listeners. All non-listener sockets MUST become permanently fenced. Invalid
 * events, configuration changes and teardown MUST revoke transport readiness.
 */
static void
ovfb_fence(struct ovfb_softc *sc, bool preserve_listeners)
{
    struct ovfb_pcb *pcb;

    sx_assert(&ovfb_domain_lock, SA_XLOCKED);
    if (!preserve_listeners)
        sc->ready = false;
    if (ovfb_device != sc)
        return;
    LIST_FOREACH(pcb, &ovfb_pcbs, link) {
        if (preserve_listeners && pcb->listening && !pcb->fenced)
            continue;
        ov_vsock_reset(&pcb->connection);
        pcb->fenced = true;
        pcb->bound = false;
        pcb->listening = false;
        pcb->connected = false;
        SOCK_LOCK(pcb->so);
        pcb->so->so_error = ECONNRESET;
        SOCK_UNLOCK(pcb->so);
        soisdisconnected(pcb->so);
        if (SOLISTENING(pcb->so)) {
            SOCK_LOCK(pcb->so);
            solisten_wakeup(pcb->so);
        }
    }
}

static int
ovfb_config_change(device_t dev)
{
    struct ovfb_softc *sc = device_get_softc(dev);

    mtx_lock(&sc->lock);
    sc->reset_pending = true;
    if (!sc->stopping)
        taskqueue_enqueue(taskqueue_thread, &sc->work);
    mtx_unlock(&sc->lock);
    return (0);
}

static void
ovfb_work(void *argument, int pending)
{
    struct ovfb_softc *sc = argument;
    struct ovfb_packet *packet;
    struct ovfb_pcb *pcb;
    uint32_t used;
    unsigned processed;
    bool reset, event_received, valid_reset;
    uint64_t cid;
    int error;

    sx_xlock(&ovfb_domain_lock);
    if (!sc->ready) {
        sx_xunlock(&ovfb_domain_lock);
        return;
    }
    mtx_lock(&sc->lock);
    while ((packet = virtqueue_dequeue(sc->tx, &used)) != NULL) {
        packet->busy = false;
        explicit_bzero(packet->data, OVFB_FRAME);
    }
    event_received = virtqueue_dequeue(sc->event, &used) != NULL;
    reset = event_received || sc->reset_pending;
    valid_reset = event_received && !sc->reset_pending &&
        used == sizeof(sc->event_data) && le32toh(sc->event_data) == 0;
    sc->reset_pending = false;
    mtx_unlock(&sc->lock);
    if (reset) {
        virtio_read_device_config(sc->dev, 0, &cid, sizeof(cid));
        valid_reset = valid_reset && le64toh(cid) == 3;
        ovfb_fence(sc, valid_reset);
        if (!valid_reset) {
            virtio_stop(sc->dev);
            sx_xunlock(&ovfb_domain_lock);
            return;
        }
        mtx_lock(&sc->lock);
        sc->event_data = 0;
        error = virtqueue_enqueue(sc->event, &sc->event_data,
            sc->event_sg, 0, sc->event_sg->sg_nseg);
        if (error == 0)
            virtqueue_notify(sc->event);
        mtx_unlock(&sc->lock);
        if (error != 0) {
            ovfb_fence(sc, false);
            virtio_stop(sc->dev);
            sx_xunlock(&ovfb_domain_lock);
            return;
        }
    }
    for (processed = 0; processed < OVFB_BUFFERS; processed++) {
        mtx_lock(&sc->lock);
        packet = virtqueue_dequeue(sc->rx, &used);
        mtx_unlock(&sc->lock);
        if (packet == NULL)
            break;
        if (used <= OVFB_FRAME)
            ovfb_receive(packet, used);
        explicit_bzero(packet->data, OVFB_FRAME);
        mtx_lock(&sc->lock);
        error = virtqueue_enqueue(sc->rx, packet, packet->sg, 0,
            packet->sg->sg_nseg);
        if (error == 0)
            virtqueue_notify(sc->rx);
        mtx_unlock(&sc->lock);
        if (error != 0) {
            ovfb_fence(sc, false);
            virtio_stop(sc->dev);
            break;
        }
    }
    LIST_FOREACH(pcb, &ovfb_pcbs, link)
        ovfb_flush(pcb);
    /* The transport interrupt filter disables queue interrupts before the
     * callback. Re-arm after every batch and close the completion race. */
    mtx_lock(&sc->lock);
    pending = 0;
    if (sc->ready) {
        pending |= virtqueue_enable_intr(sc->rx);
        pending |= virtqueue_enable_intr(sc->tx);
        pending |= virtqueue_enable_intr(sc->event);
    }
    mtx_unlock(&sc->lock);
    if (sc->ready && (processed == OVFB_BUFFERS || pending != 0))
        taskqueue_enqueue(taskqueue_thread, &sc->work);
    sx_xunlock(&ovfb_domain_lock);
}

static int
ovfb_probe(device_t dev)
{
    if (virtio_get_device_type(dev) != VIRTIO_ID_VSOCK)
        return (ENXIO);
    device_set_desc(dev, "Overalls host-only VirtIO VSOCK transport");
    return (BUS_PROBE_DEFAULT);
}

static int
ovfb_packet_init(struct ovfb_packet *packet)
{
    packet->data = malloc(OVFB_FRAME, M_OVSOCK, M_WAITOK | M_ZERO);
    packet->sg = sglist_alloc(OVFB_SEGMENTS, M_WAITOK);
    return (sglist_append(packet->sg, packet->data, OVFB_FRAME));
}

static int
ovfb_attach(device_t dev)
{
    struct ovfb_softc *sc;
    struct vq_alloc_info queues[3];
    uint64_t cid;
    unsigned i;
    int error;

    sc = device_get_softc(dev);
    sc->dev = dev;
    mtx_init(&sc->lock, "overalls_vsock_queues", NULL, MTX_DEF);
    TASK_INIT(&sc->work, 0, ovfb_work, sc);
    sx_xlock(&ovfb_domain_lock);
    if (ovfb_device != NULL) {
        sx_xunlock(&ovfb_domain_lock);
        mtx_destroy(&sc->lock);
        return (EEXIST);
    }
    ovfb_device = sc;
    sx_xunlock(&ovfb_domain_lock);
    (void)virtio_negotiate_features(dev, VIRTIO_RING_F_INDIRECT_DESC);
    error = virtio_finalize_features(dev);
    if (error != 0)
        goto fail;
    virtio_read_device_config(dev, 0, &cid, sizeof(cid));
    if (le64toh(cid) != 3) {
        error = EINVAL;
        goto fail;
    }
    VQ_ALLOC_INFO_INIT(&queues[0], OVFB_SEGMENTS, ovfb_interrupt, sc,
        &sc->rx, "%s receive", device_get_nameunit(dev));
    VQ_ALLOC_INFO_INIT(&queues[1], OVFB_SEGMENTS, ovfb_interrupt, sc,
        &sc->tx, "%s transmit", device_get_nameunit(dev));
    VQ_ALLOC_INFO_INIT(&queues[2], 1, ovfb_interrupt, sc,
        &sc->event, "%s event", device_get_nameunit(dev));
    error = virtio_alloc_virtqueues(dev, 0, 3, queues);
    if (error != 0)
        goto fail;
    sc->queues_ready = true;
    for (i = 0; i < OVFB_BUFFERS; i++) {
        error = ovfb_packet_init(&sc->rxbuf[i]);
        if (error != 0)
            goto fail;
        error = ovfb_packet_init(&sc->txbuf[i]);
        if (error != 0)
            goto fail;
        error = virtqueue_enqueue(sc->rx, &sc->rxbuf[i], sc->rxbuf[i].sg,
            0, sc->rxbuf[i].sg->sg_nseg);
        if (error != 0)
            goto fail;
    }
    sc->event_sg = sglist_build(&sc->event_data, sizeof(sc->event_data), M_WAITOK);
    error = virtqueue_enqueue(sc->event, &sc->event_data, sc->event_sg, 0,
        sc->event_sg->sg_nseg);
    if (error != 0)
        goto fail;
    error = virtio_setup_intr(dev, INTR_TYPE_NET);
    if (error != 0)
        goto fail;
    sc->interrupts_ready = true;
    sx_xlock(&ovfb_domain_lock);
    sc->ready = true;
    sx_xunlock(&ovfb_domain_lock);
    mtx_lock(&sc->lock);
    error = virtqueue_enable_intr(sc->rx);
    error |= virtqueue_enable_intr(sc->tx);
    error |= virtqueue_enable_intr(sc->event);
    virtqueue_notify(sc->rx);
    virtqueue_notify(sc->event);
    mtx_unlock(&sc->lock);
    if (error != 0)
        taskqueue_enqueue(taskqueue_thread, &sc->work);
    return (0);
fail:
    (void)ovfb_detach(dev);
    return (error);
}

/** @cc [owner:ghuntley,label:security] static-device-lifetime
 * Runtime detach MUST refuse once parent-managed interrupt handlers exist:
 * the parent tears handlers down only after this callback returns. Shutdown and
 * reset fence every socket, stop DMA, and keep fixed buffers/locks alive until
 * VM disposal. Attach failures before handler registration reclaim all buffers.
 */
static int
ovfb_stop_device(device_t dev)
{
    struct ovfb_softc *sc;

    sc = device_get_softc(dev);
    sx_xlock(&ovfb_domain_lock);
    ovfb_fence(sc, false);
    mtx_lock(&sc->lock);
    sc->stopping = true;
    if (sc->queues_ready)
        virtqueue_disable_intr(sc->rx);
    if (sc->queues_ready)
        virtqueue_disable_intr(sc->tx);
    if (sc->queues_ready)
        virtqueue_disable_intr(sc->event);
    mtx_unlock(&sc->lock);
    if (ovfb_device == sc)
        ovfb_device = NULL;
    virtio_stop(dev);
    sx_xunlock(&ovfb_domain_lock);
    taskqueue_drain(taskqueue_thread, &sc->work);
    return (0);
}

static int
ovfb_detach(device_t dev)
{
    struct ovfb_softc *sc;
    unsigned i;
    int last;

    sc = device_get_softc(dev);
    if (sc->interrupts_ready)
        return (EBUSY);
    (void)ovfb_stop_device(dev);
    if (sc->queues_ready) {
        for (last = 0; virtqueue_drain(sc->rx, &last) != NULL; )
            ;
        for (last = 0; virtqueue_drain(sc->tx, &last) != NULL; )
            ;
        for (last = 0; virtqueue_drain(sc->event, &last) != NULL; )
            ;
    }
    for (i = 0; i < OVFB_BUFFERS; i++) {
        if (sc->rxbuf[i].sg != NULL)
            sglist_free(sc->rxbuf[i].sg);
        if (sc->txbuf[i].sg != NULL)
            sglist_free(sc->txbuf[i].sg);
        if (sc->rxbuf[i].data != NULL) {
            explicit_bzero(sc->rxbuf[i].data, OVFB_FRAME);
            free(sc->rxbuf[i].data, M_OVSOCK);
        }
        if (sc->txbuf[i].data != NULL) {
            explicit_bzero(sc->txbuf[i].data, OVFB_FRAME);
            free(sc->txbuf[i].data, M_OVSOCK);
        }
    }
    if (sc->event_sg != NULL)
        sglist_free(sc->event_sg);
    mtx_destroy(&sc->lock);
    return (0);
}

static device_method_t ovfb_methods[] = {
    DEVMETHOD(device_probe, ovfb_probe),
    DEVMETHOD(device_attach, ovfb_attach),
    DEVMETHOD(device_detach, ovfb_detach),
    DEVMETHOD(device_shutdown, ovfb_stop_device),
    DEVMETHOD(virtio_config_change, ovfb_config_change),
    DEVMETHOD_END
};
static int
ovfb_modevent(module_t module, int event, void *unused)
{
    switch (event) {
    case MOD_LOAD:
    case MOD_SHUTDOWN:
        return (0);
    case MOD_QUIESCE:
    case MOD_UNLOAD:
        /* The socket domain is a static kernel facility. */
        return (EBUSY);
    default:
        return (EOPNOTSUPP);
    }
}
static driver_t ovfb_driver = {
    "virtio_vsock", ovfb_methods, sizeof(struct ovfb_softc)
};
VIRTIO_DRIVER_MODULE(virtio_vsock, ovfb_driver, ovfb_modevent, NULL);
MODULE_VERSION(virtio_vsock, 1);
MODULE_DEPEND(virtio_vsock, virtio, 1, 1, 1);

/* SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Overalls contributors.
 */
#include "ov_vsock.h"

static uint32_t
load32(const unsigned char *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
        (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t
load64(const unsigned char *p)
{
    return (uint64_t)load32(p) | (uint64_t)load32(p + 4) << 32;
}

static void
store32(unsigned char *p, uint32_t n)
{
    p[0] = (unsigned char)n;
    p[1] = (unsigned char)(n >> 8);
    p[2] = (unsigned char)(n >> 16);
    p[3] = (unsigned char)(n >> 24);
}

static void
store64(unsigned char *p, uint64_t n)
{
    store32(p, (uint32_t)n);
    store32(p + 4, (uint32_t)(n >> 32));
}

static int
valid_header(const struct ov_vsock_header *h, uint64_t source, uint64_t target)
{
    if (h == 0 || h->src_cid != source || h->dst_cid != target ||
        h->src_port == 0 || h->dst_port == 0 || h->type != OV_VSOCK_STREAM ||
        h->op < OV_VSOCK_REQUEST || h->op > OV_VSOCK_CREDIT_REQUEST ||
        h->len > OV_VSOCK_MAX_PAYLOAD ||
        h->buf_alloc > OV_VSOCK_MAX_PEER_WINDOW)
        return 0;
    if (h->op != OV_VSOCK_RW && h->len != 0)
        return 0;
    if (h->op == OV_VSOCK_SHUTDOWN)
        return h->flags != 0 && (h->flags & ~3U) == 0;
    return h->flags == 0;
}

enum ov_vsock_result
ov_vsock_decode(const void *frame, size_t used, struct ov_vsock_header *output)
{
    const unsigned char *p = frame;
    struct ov_vsock_header h;
    if (p == 0 || output == 0 || used < OV_VSOCK_HEADER_BYTES ||
        used > OV_VSOCK_HEADER_BYTES + OV_VSOCK_MAX_PAYLOAD)
        return OV_VSOCK_INVALID;
    h.src_cid = load64(p);
    h.dst_cid = load64(p + 8);
    h.src_port = load32(p + 16);
    h.dst_port = load32(p + 20);
    h.len = load32(p + 24);
    h.type = (uint16_t)((uint16_t)p[28] | (uint16_t)p[29] << 8);
    h.op = (uint16_t)((uint16_t)p[30] | (uint16_t)p[31] << 8);
    h.flags = load32(p + 32);
    h.buf_alloc = load32(p + 36);
    h.fwd_cnt = load32(p + 40);
    if (!valid_header(&h, OV_VSOCK_HOST_CID, OV_VSOCK_GUEST_CID) ||
        used - OV_VSOCK_HEADER_BYTES != h.len)
        return OV_VSOCK_INVALID;
    *output = h;
    return OV_VSOCK_OK;
}

enum ov_vsock_result
ov_vsock_encode(void *buffer, size_t capacity, const struct ov_vsock_header *h)
{
    unsigned char *p = buffer;
    if (p == 0 || capacity < OV_VSOCK_HEADER_BYTES ||
        !valid_header(h, OV_VSOCK_GUEST_CID, OV_VSOCK_HOST_CID))
        return OV_VSOCK_INVALID;
    store64(p, h->src_cid);
    store64(p + 8, h->dst_cid);
    store32(p + 16, h->src_port);
    store32(p + 20, h->dst_port);
    store32(p + 24, h->len);
    p[28] = (unsigned char)h->type;
    p[29] = (unsigned char)(h->type >> 8);
    p[30] = (unsigned char)h->op;
    p[31] = (unsigned char)(h->op >> 8);
    store32(p + 32, h->flags);
    store32(p + 36, h->buf_alloc);
    store32(p + 40, h->fwd_cnt);
    return OV_VSOCK_OK;
}

enum ov_vsock_result
ov_vsock_connection_init(struct ov_vsock_connection *c, uint32_t local_port,
    uint32_t peer_port, uint32_t window)
{
    if (c == 0 || local_port == 0 || peer_port == 0 || window == 0 ||
        window > OV_VSOCK_MAX_PAYLOAD)
        return OV_VSOCK_INVALID;
    *c = (struct ov_vsock_connection){0};
    c->local_port = local_port;
    c->peer_port = peer_port;
    c->receive_window = window;
    return OV_VSOCK_OK;
}

enum ov_vsock_action
ov_vsock_receive(struct ov_vsock_connection *c, const struct ov_vsock_header *h)
{
    uint32_t outstanding;
    uint32_t advanced;
    uint32_t pending;
    enum ov_vsock_action action;

    if (c == 0 || !valid_header(h, OV_VSOCK_HOST_CID, OV_VSOCK_GUEST_CID) ||
        c->local_port != h->dst_port || c->peer_port != h->src_port ||
        c->phase == OV_VSOCK_CLOSED)
        return OV_VSOCK_REFUSED;
    if (h->op == OV_VSOCK_RST) {
        ov_vsock_reset(c);
        return OV_VSOCK_CONNECTION_CLOSED;
    }
    outstanding = c->tx_cnt - c->peer_fwd_cnt;
    advanced = h->fwd_cnt - c->peer_fwd_cnt;
    if (advanced > outstanding || outstanding - advanced > h->buf_alloc)
        return OV_VSOCK_REFUSED;
    if (c->phase == OV_VSOCK_NEW) {
        if (h->op != OV_VSOCK_REQUEST)
            return OV_VSOCK_REFUSED;
        action = OV_VSOCK_ACCEPT_REQUEST;
    } else if (c->phase != OV_VSOCK_ESTABLISHED) {
        return OV_VSOCK_REFUSED;
    } else {
        switch (h->op) {
        case OV_VSOCK_RW:
            pending = c->rx_cnt - c->rx_fwd_cnt;
            if (pending > c->receive_window ||
                h->len > c->receive_window - pending ||
                (c->local_shutdown & OV_VSOCK_SHUTDOWN_RECEIVE) != 0 ||
                (c->peer_shutdown & OV_VSOCK_SHUTDOWN_SEND) != 0)
                return OV_VSOCK_REFUSED;
            action = OV_VSOCK_DELIVER_DATA;
            break;
        case OV_VSOCK_SHUTDOWN:
            action = OV_VSOCK_PEER_SHUTDOWN;
            break;
        case OV_VSOCK_CREDIT_REQUEST:
            action = OV_VSOCK_SEND_CREDIT;
            break;
        case OV_VSOCK_CREDIT_UPDATE:
            action = OV_VSOCK_NONE;
            break;
        default:
            return OV_VSOCK_REFUSED;
        }
    }
    c->peer_buf_alloc = h->buf_alloc;
    c->peer_fwd_cnt = h->fwd_cnt;
    if (action == OV_VSOCK_ACCEPT_REQUEST)
        c->phase = OV_VSOCK_REQUESTED;
    else if (action == OV_VSOCK_DELIVER_DATA)
        c->rx_cnt += h->len;
    else if (action == OV_VSOCK_PEER_SHUTDOWN)
        c->peer_shutdown |= h->flags;
    return action;
}

enum ov_vsock_result
ov_vsock_accept(struct ov_vsock_connection *c)
{
    if (c == 0 || c->phase != OV_VSOCK_REQUESTED)
        return OV_VSOCK_INVALID;
    c->phase = OV_VSOCK_ESTABLISHED;
    return OV_VSOCK_OK;
}

uint32_t
ov_vsock_tx_credit(const struct ov_vsock_connection *c)
{
    uint32_t outstanding;
    if (c == 0 || c->phase != OV_VSOCK_ESTABLISHED ||
        (c->local_shutdown & OV_VSOCK_SHUTDOWN_SEND) != 0 ||
        (c->peer_shutdown & OV_VSOCK_SHUTDOWN_RECEIVE) != 0)
        return 0;
    outstanding = c->tx_cnt - c->peer_fwd_cnt;
    return outstanding <= c->peer_buf_alloc ? c->peer_buf_alloc - outstanding : 0;
}

enum ov_vsock_result
ov_vsock_sent(struct ov_vsock_connection *c, uint32_t bytes)
{
    if (c == 0 || c->phase != OV_VSOCK_ESTABLISHED ||
        bytes > OV_VSOCK_MAX_PAYLOAD || bytes > ov_vsock_tx_credit(c) ||
        (c->local_shutdown & OV_VSOCK_SHUTDOWN_SEND) != 0 ||
        (c->peer_shutdown & OV_VSOCK_SHUTDOWN_RECEIVE) != 0)
        return OV_VSOCK_INVALID;
    c->tx_cnt += bytes;
    return OV_VSOCK_OK;
}

enum ov_vsock_result
ov_vsock_consumed(struct ov_vsock_connection *c, uint32_t bytes)
{
    if (c == 0 || c->phase != OV_VSOCK_ESTABLISHED ||
        bytes > c->rx_cnt - c->rx_fwd_cnt)
        return OV_VSOCK_INVALID;
    c->rx_fwd_cnt += bytes;
    return OV_VSOCK_OK;
}

enum ov_vsock_result
ov_vsock_shutdown(struct ov_vsock_connection *c, uint32_t flags)
{
    if (c == 0 || c->phase != OV_VSOCK_ESTABLISHED || flags == 0 ||
        (flags & ~3U) != 0)
        return OV_VSOCK_INVALID;
    c->local_shutdown |= flags;
    return OV_VSOCK_OK;
}

void
ov_vsock_reset(struct ov_vsock_connection *c)
{
    if (c == 0)
        return;
    *c = (struct ov_vsock_connection){0};
    c->phase = OV_VSOCK_CLOSED;
}

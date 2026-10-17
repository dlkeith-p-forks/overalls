/* SPDX-License-Identifier: BSD-2-Clause */
#include "ov_vsock.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static struct ov_vsock_header
incoming(uint16_t operation)
{
    struct ov_vsock_header h = {0};
    h.src_cid = OV_VSOCK_HOST_CID;
    h.dst_cid = OV_VSOCK_GUEST_CID;
    h.src_port = 40001;
    h.dst_port = 1098;
    h.type = OV_VSOCK_STREAM;
    h.op = operation;
    h.buf_alloc = 64;
    return h;
}

static struct ov_vsock_connection
connected(void)
{
    struct ov_vsock_connection c;
    struct ov_vsock_header h = incoming(OV_VSOCK_REQUEST);
    assert(ov_vsock_connection_init(&c, 1098, 40001, 64) == OV_VSOCK_OK);
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_ACCEPT_REQUEST);
    assert(ov_vsock_accept(&c) == OV_VSOCK_OK);
    return c;
}

static void
refused_unchanged(struct ov_vsock_connection *c,
    const struct ov_vsock_header *h)
{
    struct ov_vsock_connection before = *c;
    assert(ov_vsock_receive(c, h) == OV_VSOCK_REFUSED);
    assert(memcmp(c, &before, sizeof(before)) == 0);
}

static void
sent_refused_unchanged(struct ov_vsock_connection *c)
{
    struct ov_vsock_connection before = *c;
    assert(ov_vsock_sent(c, 1) == OV_VSOCK_INVALID);
    assert(memcmp(c, &before, sizeof(before)) == 0);
}

/** @cc [owner:ghuntley,label:verification] directional-half-close
 * Local SEND or peer RECEIVE MUST stop only local transmission. Local RECEIVE
 * or peer SEND MUST stop only remote data delivery. Buffered received bytes
 * MUST remain consumable after a peer SEND shutdown.
 */
static void
directional_half_close(void)
{
    struct ov_vsock_connection c = connected();
    struct ov_vsock_header h = incoming(OV_VSOCK_RW);
    h.len = 8;
    assert(ov_vsock_sent(&c, 8) == OV_VSOCK_OK);
    assert(ov_vsock_shutdown(&c, OV_VSOCK_SHUTDOWN_SEND) == OV_VSOCK_OK);
    assert(ov_vsock_tx_credit(&c) == 0);
    sent_refused_unchanged(&c);
    h.fwd_cnt = 8;
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_DELIVER_DATA);
    h.op = OV_VSOCK_SHUTDOWN;
    h.flags = OV_VSOCK_SHUTDOWN_SEND;
    h.len = 0;
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_PEER_SHUTDOWN);
    assert(ov_vsock_consumed(&c, 8) == OV_VSOCK_OK);
    h.op = OV_VSOCK_RW;
    h.flags = 0;
    h.len = 1;
    refused_unchanged(&c, &h);

    c = connected();
    h = incoming(OV_VSOCK_SHUTDOWN);
    h.flags = OV_VSOCK_SHUTDOWN_RECEIVE;
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_PEER_SHUTDOWN);
    assert(ov_vsock_tx_credit(&c) == 0);
    sent_refused_unchanged(&c);
    h.op = OV_VSOCK_RW;
    h.flags = 0;
    h.len = 8;
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_DELIVER_DATA);
    assert(ov_vsock_consumed(&c, 8) == OV_VSOCK_OK);

    c = connected();
    h = incoming(OV_VSOCK_SHUTDOWN);
    h.flags = OV_VSOCK_SHUTDOWN_SEND;
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_PEER_SHUTDOWN);
    assert(ov_vsock_sent(&c, 8) == OV_VSOCK_OK);
    h.op = OV_VSOCK_RW;
    h.flags = 0;
    h.len = 1;
    refused_unchanged(&c, &h);
    h.op = OV_VSOCK_CREDIT_UPDATE;
    h.len = 0;
    h.fwd_cnt = 8;
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_NONE);
    assert(ov_vsock_tx_credit(&c) == 64);

    c = connected();
    assert(ov_vsock_shutdown(&c, OV_VSOCK_SHUTDOWN_RECEIVE) == OV_VSOCK_OK);
    assert(ov_vsock_sent(&c, 8) == OV_VSOCK_OK);
    h = incoming(OV_VSOCK_RW);
    h.len = 1;
    refused_unchanged(&c, &h);
}

/** @cc [owner:ghuntley,label:verification] shutdown-order-and-refusal
 * Both peer shutdown directions MUST accumulate monotonically in either order.
 * Invalid shutdown flags, control payloads and acknowledgements of unsent bytes
 * MUST leave every connection field unchanged.
 */
static void
shutdown_order_and_refusal(void)
{
    for (uint32_t first = 1; first <= 2; ++first) {
        struct ov_vsock_connection c = connected();
        struct ov_vsock_header h = incoming(OV_VSOCK_SHUTDOWN);
        h.flags = first;
        assert(ov_vsock_receive(&c, &h) == OV_VSOCK_PEER_SHUTDOWN);
        h.flags = 3U - first;
        assert(ov_vsock_receive(&c, &h) == OV_VSOCK_PEER_SHUTDOWN);
        assert(c.peer_shutdown == 3);
        assert(ov_vsock_tx_credit(&c) == 0);
        h.flags = first;
        assert(ov_vsock_receive(&c, &h) == OV_VSOCK_PEER_SHUTDOWN);
        assert(c.peer_shutdown == 3);
        h.op = OV_VSOCK_CREDIT_REQUEST;
        h.flags = 0;
        assert(ov_vsock_receive(&c, &h) == OV_VSOCK_SEND_CREDIT);
    }

    struct ov_vsock_connection c = connected();
    struct ov_vsock_header h = incoming(OV_VSOCK_SHUTDOWN);
    for (uint32_t flags = 0; flags <= 8; flags += 4) {
        h.flags = flags;
        refused_unchanged(&c, &h);
    }
    h.flags = OV_VSOCK_SHUTDOWN_SEND;
    h.len = 1;
    refused_unchanged(&c, &h);
    h.len = 0;
    h.fwd_cnt = 1;
    refused_unchanged(&c, &h);
    assert(c.peer_shutdown == 0);
    assert(ov_vsock_tx_credit(&c) == 64);
}

/** @cc [owner:ghuntley,label:verification] partial-credit-rollover
 * A valid partial forward acknowledgement across counter wrap MUST release
 * exactly those bytes; stale or over-window acknowledgements/data MUST refuse
 * unchanged. Local consumption MUST preserve the same modulo receive balance.
 */
static void
partial_credit_rollover(void)
{
    struct ov_vsock_connection c = connected();
    struct ov_vsock_header h = incoming(OV_VSOCK_CREDIT_UPDATE);
    c.tx_cnt = c.peer_fwd_cnt = 0xffffffe0U;
    assert(ov_vsock_sent(&c, 48) == OV_VSOCK_OK);
    assert(c.tx_cnt == 16);
    h.fwd_cnt = 0;
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_NONE);
    assert(ov_vsock_tx_credit(&c) == 48);
    h.fwd_cnt = 0xffffffe0U;
    refused_unchanged(&c, &h);
    h.fwd_cnt = 16;
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_NONE);
    assert(ov_vsock_tx_credit(&c) == 64);
    c.rx_cnt = c.rx_fwd_cnt = 0xfffffffcU;
    h.op = OV_VSOCK_RW;
    h.len = 8;
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_DELIVER_DATA);
    assert(c.rx_cnt == 4);
    assert(ov_vsock_consumed(&c, 3) == OV_VSOCK_OK);
    assert(c.rx_fwd_cnt == 0xffffffffU);
    h.len = 60;
    refused_unchanged(&c, &h);
    assert(ov_vsock_consumed(&c, 5) == OV_VSOCK_OK);
    assert(c.rx_fwd_cnt == c.rx_cnt);
}

int
main(void)
{
    directional_half_close();
    shutdown_order_and_refusal();
    partial_credit_rollover();
    puts("independent directional shutdown and partial-credit rollover vectors passed");
    return 0;
}

/* SPDX-License-Identifier: BSD-2-Clause */
#include "ov_vsock.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static struct ov_vsock_header
incoming(uint16_t op)
{
    struct ov_vsock_header h = {0};
    h.src_cid = OV_VSOCK_HOST_CID;
    h.dst_cid = OV_VSOCK_GUEST_CID;
    h.src_port = 40001;
    h.dst_port = 1098;
    h.type = OV_VSOCK_STREAM;
    h.op = op;
    h.buf_alloc = 65536;
    return h;
}

static struct ov_vsock_connection
connected(void)
{
    struct ov_vsock_connection c;
    struct ov_vsock_header h = incoming(OV_VSOCK_REQUEST);
    assert(ov_vsock_connection_init(&c, 1098, 40001, 65536) == OV_VSOCK_OK);
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_ACCEPT_REQUEST);
    assert(ov_vsock_tx_credit(&c) == 0);
    assert(ov_vsock_accept(&c) == OV_VSOCK_OK);
    assert(ov_vsock_tx_credit(&c) == 65536);
    return c;
}

static void
wire_vectors(void)
{
    const unsigned char request[44] = {
        2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0,
        0x41, 0x9c, 0, 0, 0x4a, 4, 0, 0, 0, 0, 0, 0,
        1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0
    };
    unsigned char bytes[44];
    struct ov_vsock_header h;
    struct ov_vsock_header unchanged;
    assert(ov_vsock_decode(request, sizeof(request), &h) == OV_VSOCK_OK);
    assert(h.src_port == 40001 && h.dst_port == 1098 && h.buf_alloc == 65536);
    h.src_cid = 3;
    h.dst_cid = 2;
    assert(ov_vsock_encode(bytes, sizeof(bytes), &h) == OV_VSOCK_OK);
    assert(bytes[0] == 3 && bytes[8] == 2);
    assert(memcmp(bytes + 16, request + 16, 28) == 0);
    memset(&unchanged, 0xa5, sizeof(unchanged));
    for (size_t size = 0; size < 44; ++size) {
        h = unchanged;
        assert(ov_vsock_decode(request, size, &h) == OV_VSOCK_INVALID);
        assert(memcmp(&h, &unchanged, sizeof(h)) == 0);
    }
    for (size_t field = 0; field < 44; ++field) {
        memcpy(bytes, request, 44);
        bytes[field] ^= 0x80;
        h = unchanged;
        if (ov_vsock_decode(bytes, 44, &h) == OV_VSOCK_INVALID)
            assert(memcmp(&h, &unchanged, sizeof(h)) == 0);
    }
    assert(ov_vsock_decode(NULL, 44, &h) == OV_VSOCK_INVALID);
    assert(ov_vsock_decode(request, 44, NULL) == OV_VSOCK_INVALID);
    assert(ov_vsock_decode(request, (size_t)-1, &h) == OV_VSOCK_INVALID);
}

static void
credit_and_rollover(void)
{
    struct ov_vsock_connection c = connected();
    struct ov_vsock_connection before;
    struct ov_vsock_header h = incoming(OV_VSOCK_CREDIT_UPDATE);
    assert(ov_vsock_sent(&c, 65536) == OV_VSOCK_OK);
    assert(ov_vsock_tx_credit(&c) == 0);
    assert(ov_vsock_sent(&c, 1) == OV_VSOCK_INVALID);
    before = c;
    h.fwd_cnt = 65537;
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_REFUSED);
    assert(memcmp(&before, &c, sizeof(c)) == 0);
    h.fwd_cnt = 65536;
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_NONE);
    assert(ov_vsock_tx_credit(&c) == 65536);
    /* Valid windows spanning the 32-bit counter boundary retain exact credit. */
    c.tx_cnt = 0xfffffff0U;
    c.peer_fwd_cnt = 0xfffffff0U;
    assert(ov_vsock_sent(&c, 32) == OV_VSOCK_OK);
    assert(c.tx_cnt == 16 && ov_vsock_tx_credit(&c) == 65504);
    h.fwd_cnt = 16;
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_NONE);
    assert(ov_vsock_tx_credit(&c) == 65536);
    c.rx_cnt = c.rx_fwd_cnt = 0xfffffff0U;
    h.op = OV_VSOCK_RW;
    h.len = 65536;
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_DELIVER_DATA);
    assert(c.rx_cnt - c.rx_fwd_cnt == 65536);
    assert(ov_vsock_receive(&c, &h) == OV_VSOCK_REFUSED);
    assert(ov_vsock_consumed(&c, 65536) == OV_VSOCK_OK);
    assert(c.rx_cnt == c.rx_fwd_cnt);
    assert(ov_vsock_consumed(&c, 1) == OV_VSOCK_INVALID);
}

static uint32_t
random32(uint32_t *seed)
{
    uint32_t n = *seed;
    n ^= n << 13;
    n ^= n >> 17;
    n ^= n << 5;
    *seed = n;
    return n;
}

/** @cc [owner:ghuntley,label:verification] native-vsock-generated-state-property
 * This property test MUST generate peer frames and local transitions against
 * the actual shared core, asserting unchanged state on refusal, bounded windows
 * and acknowledgement counters across both fixed seeds. It MUST NOT substitute
 * a duplicated state machine or claim target wrapper or DMA execution.
 */
static void
state_properties(uint32_t seed)
{
    struct ov_vsock_connection c = connected();
    for (uint32_t iteration = 0; iteration < 200000; ++iteration) {
        struct ov_vsock_header h = incoming(OV_VSOCK_CREDIT_UPDATE);
        struct ov_vsock_connection before = c;
        uint32_t n = random32(&seed);
        enum ov_vsock_action action;
        h.fwd_cnt = c.peer_fwd_cnt;
        switch (n % 10) {
        case 0:
            h.src_cid = (uint64_t)random32(&seed) + 4;
            break;
        case 1:
            h.dst_cid = (uint64_t)random32(&seed) + 4;
            break;
        case 2:
            h.fwd_cnt = c.tx_cnt + 1;
            break;
        case 3:
            h.buf_alloc = OV_VSOCK_MAX_PEER_WINDOW + 1;
            break;
        case 4:
            h.op = OV_VSOCK_RW;
            h.len = random32(&seed) % (OV_VSOCK_MAX_PAYLOAD + 2);
            break;
        case 5:
            h.op = OV_VSOCK_CREDIT_REQUEST;
            break;
        case 6:
            h.op = OV_VSOCK_SHUTDOWN;
            h.flags = (random32(&seed) % 3) + 1;
            break;
        case 7:
            h.op = OV_VSOCK_RST;
            break;
        case 8:
            h.fwd_cnt = c.tx_cnt;
            break;
        default:
            h.flags = random32(&seed) | 4U;
            break;
        }
        action = ov_vsock_receive(&c, &h);
        if (action == OV_VSOCK_REFUSED)
            assert(memcmp(&c, &before, sizeof(c)) == 0);
        if (n % 10 < 4 || n % 10 == 9)
            assert(action == OV_VSOCK_REFUSED);
        assert(c.rx_cnt - c.rx_fwd_cnt <= c.receive_window);
        assert(ov_vsock_tx_credit(&c) <= OV_VSOCK_MAX_PEER_WINDOW);
        if (c.phase == OV_VSOCK_ESTABLISHED) {
            uint32_t bytes = random32(&seed) % 65537;
            uint32_t credit = ov_vsock_tx_credit(&c);
            enum ov_vsock_result result = ov_vsock_sent(&c, bytes);
            if (result == OV_VSOCK_OK)
                assert(ov_vsock_tx_credit(&c) == credit - bytes);
            assert(ov_vsock_consumed(&c, c.rx_cnt - c.rx_fwd_cnt) == OV_VSOCK_OK);
        } else {
            assert(c.phase == OV_VSOCK_CLOSED);
            assert(ov_vsock_tx_credit(&c) == 0);
            assert(ov_vsock_sent(&c, 1) == OV_VSOCK_INVALID);
            c = connected();
        }
    }
}

int
main(void)
{
    wire_vectors();
    credit_and_rollover();
    state_properties(0x12345678U);
    state_properties(0xfeedbeefU);
    puts("native vsock parser/credit properties passed (400000 transitions)");
    return 0;
}

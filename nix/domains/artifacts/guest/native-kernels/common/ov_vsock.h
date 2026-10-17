/* SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Overalls contributors.
 */
#ifndef OVERALLS_OV_VSOCK_H
#define OVERALLS_OV_VSOCK_H

#ifdef _KERNEL
#include <sys/types.h>
#else
#include <stddef.h>
#include <stdint.h>
#endif

#define OV_VSOCK_HEADER_BYTES 44U
#define OV_VSOCK_MAX_PAYLOAD 65536U
#define OV_VSOCK_MAX_PEER_WINDOW 16777216U
#define OV_VSOCK_HOST_CID 2U
#define OV_VSOCK_GUEST_CID 3U
#define OV_VSOCK_STREAM 1U
#define OV_VSOCK_REQUEST 1U
#define OV_VSOCK_RESPONSE 2U
#define OV_VSOCK_RST 3U
#define OV_VSOCK_SHUTDOWN 4U
#define OV_VSOCK_RW 5U
#define OV_VSOCK_CREDIT_UPDATE 6U
#define OV_VSOCK_CREDIT_REQUEST 7U
#define OV_VSOCK_SHUTDOWN_RECEIVE 1U
#define OV_VSOCK_SHUTDOWN_SEND 2U

struct ov_vsock_header {
    uint64_t src_cid;
    uint64_t dst_cid;
    uint32_t src_port;
    uint32_t dst_port;
    uint32_t len;
    uint16_t type;
    uint16_t op;
    uint32_t flags;
    uint32_t buf_alloc;
    uint32_t fwd_cnt;
};

enum ov_vsock_result {
    OV_VSOCK_OK = 0,
    OV_VSOCK_INVALID = 1
};

enum ov_vsock_phase {
    OV_VSOCK_NEW = 0,
    OV_VSOCK_REQUESTED = 1,
    OV_VSOCK_ESTABLISHED = 2,
    OV_VSOCK_CLOSED = 3
};

enum ov_vsock_action {
    OV_VSOCK_NONE = 0,
    OV_VSOCK_ACCEPT_REQUEST = 1,
    OV_VSOCK_DELIVER_DATA = 2,
    OV_VSOCK_PEER_SHUTDOWN = 3,
    OV_VSOCK_CONNECTION_CLOSED = 4,
    OV_VSOCK_SEND_CREDIT = 5,
    OV_VSOCK_REFUSED = 6
};

struct ov_vsock_connection {
    uint32_t local_port;
    uint32_t peer_port;
    uint32_t receive_window;
    uint32_t peer_buf_alloc;
    uint32_t peer_fwd_cnt;
    uint32_t tx_cnt;
    uint32_t rx_cnt;
    uint32_t rx_fwd_cnt;
    uint32_t peer_shutdown;
    uint32_t local_shutdown;
    enum ov_vsock_phase phase;
};

/** @cc [owner:ghuntley,label:security;protocol] native-vsock-frame-validation
 * Decoding MUST check the complete 44-byte little-endian header and exact used
 * length, STREAM type, host CID 2, guest CID 3, nonzero ports and bounded payload
 * before returning any header. Only SHUTDOWN carries flags; only RW carries
 * payload. Failure MUST leave the output untouched. Encoding emits guest-to-host
 * headers only and never reads or copies payload bytes.
 */
enum ov_vsock_result ov_vsock_decode(const void *, size_t,
    struct ov_vsock_header *);
enum ov_vsock_result ov_vsock_encode(void *, size_t,
    const struct ov_vsock_header *);

/** @cc [owner:ghuntley,label:security;recovery] native-vsock-stream-credit
 * The caller MUST serialize connection access and own socket lifetime, queue
 * buffers and reset fencing. The core allocates nothing. Receive refusal MUST
 * leave state untouched; the wrapper MUST reset/refuse the affected connection.
 * Forward counters use modulo-2^32 arithmetic with windows bounded below 2^31,
 * reject acknowledgement of unsent bytes, and never grant more receive/transmit
 * credit than the current window. Port/CID checks precede every transition.
 */
enum ov_vsock_result ov_vsock_connection_init(struct ov_vsock_connection *,
    uint32_t, uint32_t, uint32_t);
enum ov_vsock_action ov_vsock_receive(struct ov_vsock_connection *,
    const struct ov_vsock_header *);
enum ov_vsock_result ov_vsock_accept(struct ov_vsock_connection *);
uint32_t ov_vsock_tx_credit(const struct ov_vsock_connection *);
enum ov_vsock_result ov_vsock_sent(struct ov_vsock_connection *, uint32_t);
enum ov_vsock_result ov_vsock_consumed(struct ov_vsock_connection *, uint32_t);
enum ov_vsock_result ov_vsock_shutdown(struct ov_vsock_connection *, uint32_t);
void ov_vsock_reset(struct ov_vsock_connection *);

#endif

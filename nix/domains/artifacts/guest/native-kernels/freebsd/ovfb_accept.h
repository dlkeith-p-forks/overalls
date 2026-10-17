/* SPDX-License-Identifier: BSD-2-Clause */

/** @cc [owner:ghuntley,label:security;recovery] freebsd-unpublished-accept-cleanup
 * Invalid requests MUST allocate no child socket. A child MUST remain outside
 * the listener queues until validation and RESPONSE enqueue succeed. Failure
 * before publication MUST release its PCB and unreferenced socket exactly once.
 */
static void
ovfb_new_connection(const struct ov_vsock_header *header,
    struct ovfb_pcb *listener)
{
    struct ov_vsock_connection connection;
    struct ovfb_pcb *pcb;
    struct socket *so;

    if (ov_vsock_connection_init(&connection, header->dst_port,
        header->src_port, OVFB_WINDOW) != OV_VSOCK_OK ||
        ov_vsock_receive(&connection, header) != OV_VSOCK_ACCEPT_REQUEST ||
        ov_vsock_accept(&connection) != OV_VSOCK_OK) {
        ovfb_refuse(header);
        return;
    }
    /* solisten_clone returns an unqueued socket with zero references. */
    so = solisten_clone(listener->so);
    if (so == NULL) {
        ovfb_refuse(header);
        return;
    }
    if (ovfb_attach_socket(so, 0, NULL) != 0) {
        sodealloc(so);
        ovfb_refuse(header);
        return;
    }
    pcb = so->so_pcb;
    pcb->bound = true;
    pcb->local_port = header->dst_port;
    pcb->peer_port = header->src_port;
    pcb->connection = connection;
    if (ovfb_control(pcb, OV_VSOCK_RESPONSE, 0) != 0) {
        ovfb_detach_socket(so);
        sodealloc(so);
        ovfb_refuse(header);
        return;
    }
    pcb->connected = true;
    /* Publication establishes the queue references; no failure cleanup follows.
     * Keep soisconnected for the native accept-filter promotion path. */
    (void)solisten_enqueue(so, 0);
    soisconnected(so);
}

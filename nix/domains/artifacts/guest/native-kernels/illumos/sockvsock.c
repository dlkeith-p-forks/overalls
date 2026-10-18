/* SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Overalls contributors.
 */
#include <sys/types.h>
#include <sys/conf.h>
#include <sys/modctl.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/socket.h>
#include <sys/stropts.h>
#include <sys/sysmacros.h>
#include <sys/socketvar.h>
#include <sys/socket_proto.h>
#include <sys/uio.h>
#include <sys/poll.h>
#include <sys/errno.h>
#include <sys/debug.h>
#include <sys/policy.h>
#include <sys/zone.h>
#include <sys/time.h>
#include <sys/sockio.h>
#include <sys/filio.h>
#include "viosock.h"

#define VS_NOTIFY_READ 1U
#define VS_NOTIFY_WRITE 2U
#define VS_NOTIFY_EOF 4U
#define VS_NOTIFY_ERROR 8U
#define VS_NOTIFY_SEND_CLOSED 16U

struct vs_socket {
	struct vs_socket *next;
	kcondvar_t cv;
	sock_upper_handle_t upper;
	sock_upcalls_t *upcalls;
	struct ov_vsock_connection connection;
	uint32_t local_port;
	uint32_t peer_port;
	uint32_t head;
	uint32_t used;
	uint32_t shutdown_pending;
	uint_t refs;
	int error;
	clock_t receive_timeout;
	clock_t send_timeout;
	boolean_t bound;
	boolean_t listening;
	boolean_t closing;
	boolean_t async_close;
	boolean_t handshake;
	boolean_t reading;
	boolean_t sending;
	boolean_t credit_pending;
	boolean_t credit_requested;
	uint8_t receive[OV_ILLUMOS_WINDOW];
	uint8_t transmit[OV_VSOCK_MAX_PAYLOAD];
};

static kmutex_t vs_lock;
static struct vs_socket *vs_sockets;
static uint_t vs_allocated;
static uint32_t vs_ephemeral = 49152U;
static sock_downcalls_t vs_downcalls;

/** @cc [owner:ghuntley,label:security;recovery] illumos-vsock-endpoint-lifetime
 * vs_lock MUST serialize registry, stream state, bounded buffers and references.
 * The owner reference lasts until sd_close. Every unlocked copy or upcall MUST
 * hold an extra reference. An asynchronous close MUST retain the upper socket
 * until the last reference sends su_closed, and MUST remove the registry entry
 * before releasing the owner reference. No upcall may hold vs_lock.
 */
static void
vs_put(struct vs_socket *endpoint)
{
	sock_upper_handle_t upper;
	sock_upcalls_t *upcalls;
	boolean_t asynchronous;
	mutex_enter(&vs_lock);
	VERIFY3U(endpoint->refs, >, 0);
	if (--endpoint->refs != 0) {
		mutex_exit(&vs_lock);
		return;
	}
	VERIFY(endpoint->closing);
	VERIFY3U(vs_allocated, >, 0);
	vs_allocated--;
	upper = endpoint->upper;
	upcalls = endpoint->upcalls;
	asynchronous = endpoint->async_close;
	mutex_exit(&vs_lock);
	cv_destroy(&endpoint->cv);
	kmem_free(endpoint, sizeof (*endpoint));
	if (asynchronous && upper != NULL)
		upcalls->su_closed(upper);
}

static struct vs_socket *
vs_alloc(int flags)
{
	struct vs_socket *endpoint;
	/* The allocation count includes closing sockets whose callbacks are draining. */
	if (vs_allocated == OV_ILLUMOS_MAX_SOCKETS)
		return (NULL);
	endpoint = kmem_zalloc(sizeof (*endpoint), flags);
	if (endpoint == NULL)
		return (NULL);
	cv_init(&endpoint->cv, NULL, CV_DRIVER, NULL);
	endpoint->refs = 1;
	endpoint->next = vs_sockets;
	vs_sockets = endpoint;
	vs_allocated++;
	return (endpoint);
}

static void
vs_remove(struct vs_socket *endpoint)
{
	struct vs_socket **entry = &vs_sockets;
	while (*entry != endpoint) {
		VERIFY(*entry != NULL);
		entry = &(*entry)->next;
	}
	*entry = endpoint->next;
	endpoint->next = NULL;
}

/* Caller owns a callback or downcall reference. */
static void
vs_notify(struct vs_socket *endpoint, uint_t events)
{
	sock_upper_handle_t upper;
	sock_upcalls_t *upcalls;
	uint32_t queued;
	int failure;
	int ignored;
	mutex_enter(&vs_lock);
	upper = endpoint->upper;
	upcalls = endpoint->upcalls;
	queued = endpoint->used;
	failure = endpoint->error;
	mutex_exit(&vs_lock);
	if (upper == NULL || upcalls == NULL)
		return;
	if (events & VS_NOTIFY_READ)
		(void) upcalls->su_recv(upper, NULL, queued, 0, &ignored, NULL);
	if (events & VS_NOTIFY_WRITE)
		upcalls->su_txq_full(upper, B_FALSE);
	if (events & VS_NOTIFY_EOF)
		upcalls->su_opctl(upper, SOCK_OPCTL_SHUT_RECV, 0);
	if (events & VS_NOTIFY_SEND_CLOSED)
		upcalls->su_opctl(upper, SOCK_OPCTL_SHUT_SEND, 0);
	if (events & VS_NOTIFY_ERROR)
		(void) upcalls->su_disconnected(upper, 0, failure);
}

static struct ov_vsock_header
vs_header(const struct vs_socket *endpoint, uint16_t operation, uint32_t length,
    uint32_t flags)
{
	return ((struct ov_vsock_header) {
		.src_cid = OV_VSOCK_GUEST_CID, .dst_cid = OV_VSOCK_HOST_CID,
		.src_port = endpoint->local_port, .dst_port = endpoint->peer_port,
		.len = length, .type = OV_VSOCK_STREAM, .op = operation,
		.flags = flags, .buf_alloc = OV_ILLUMOS_WINDOW,
		.fwd_cnt = endpoint->connection.rx_fwd_cnt
	});
}

static int
vs_control(struct vs_socket *endpoint, uint16_t operation, uint32_t flags)
{
	struct ov_vsock_header header = vs_header(endpoint, operation, 0, flags);
	return (viosock_xmit(&header, NULL));
}

static void
vs_refuse(const struct ov_vsock_header *received)
{
	struct ov_vsock_header header = {
		.src_cid = OV_VSOCK_GUEST_CID, .dst_cid = OV_VSOCK_HOST_CID,
		.src_port = received->dst_port, .dst_port = received->src_port,
		.type = OV_VSOCK_STREAM, .op = OV_VSOCK_RST
	};
	/* Never create a reset loop in response to a peer reset. */
	if (received->op != OV_VSOCK_RST)
		(void) viosock_xmit(&header, NULL);
}

static void
vs_fail(struct vs_socket *endpoint, int error)
{
	ov_vsock_reset(&endpoint->connection);
	endpoint->error = error;
	endpoint->handshake = B_FALSE;
	endpoint->listening = B_FALSE;
	cv_broadcast(&endpoint->cv);
}

/** @cc [owner:ghuntley,label:security;protocol] illumos-vsock-host-only-accept
 * Only decoded host-CID-2 requests may reach a bound listener. A connection MUST
 * remain send-blocked until its RESPONSE is submitted. Invalid transitions,
 * exhausted socket/buffer bounds and reset events MUST refuse/reset the affected
 * connection without exposing unvalidated bytes or logging payloads.
 */
static void
vs_receive(void *unused, const struct ov_vsock_header *header,
    const uint8_t *payload)
{
	struct vs_socket *endpoint = NULL;
	struct vs_socket *listener = NULL;
	enum ov_vsock_action action;
	uint_t notify = 0;
	(void) unused;
	mutex_enter(&vs_lock);
	for (struct vs_socket *entry = vs_sockets; entry != NULL;
	    entry = entry->next) {
		if (entry->local_port != header->dst_port || !entry->bound)
			continue;
		if (entry->peer_port == header->src_port && !entry->listening) {
			endpoint = entry;
			break;
		}
		if (entry->listening)
			listener = entry;
	}
	if (endpoint == NULL && header->op == OV_VSOCK_REQUEST && listener != NULL) {
		struct ov_vsock_connection connection;
		if (ov_vsock_connection_init(&connection, header->dst_port,
		    header->src_port, OV_ILLUMOS_WINDOW) != OV_VSOCK_OK ||
		    ov_vsock_receive(&connection, header) != OV_VSOCK_ACCEPT_REQUEST ||
		    ov_vsock_accept(&connection) != OV_VSOCK_OK)
			goto refuse;
		endpoint = vs_alloc(KM_NOSLEEP);
		if (endpoint == NULL)
			goto refuse;
		endpoint->local_port = header->dst_port;
		endpoint->peer_port = header->src_port;
		endpoint->bound = endpoint->handshake = B_TRUE;
		endpoint->receive_timeout = listener->receive_timeout;
		endpoint->send_timeout = listener->send_timeout;
		endpoint->connection = connection;
		endpoint->refs++;
		listener->refs++;
		sock_upper_handle_t parent = listener->upper;
		sock_upcalls_t *upcalls = listener->upcalls;
		mutex_exit(&vs_lock);
		sock_upper_handle_t upper = upcalls->su_newconn(parent,
		    (sock_lower_handle_t)endpoint, &vs_downcalls, NULL, 0,
		    &endpoint->upcalls);
		mutex_enter(&vs_lock);
		if (upper == NULL) {
			/* No upper endpoint was published; release its unused owner reference. */
			if (!endpoint->closing) {
				vs_remove(endpoint);
				endpoint->closing = B_TRUE;
				endpoint->refs--;
			}
			vs_refuse(header);
		} else {
			endpoint->upper = upper;
			if (endpoint->closing || endpoint->error != 0 ||
			    endpoint->connection.phase != OV_VSOCK_ESTABLISHED ||
			    listener->closing || !listener->listening ||
			    vs_control(endpoint, OV_VSOCK_RESPONSE, 0) != 0) {
				vs_fail(endpoint, ECONNRESET);
				notify = VS_NOTIFY_ERROR;
				vs_refuse(header);
			} else {
				endpoint->handshake = B_FALSE;
				cv_broadcast(&endpoint->cv);
				notify = VS_NOTIFY_WRITE;
			}
		}
		mutex_exit(&vs_lock);
		vs_notify(endpoint, notify);
		vs_put(endpoint);
		vs_put(listener);
		return;
	}
	if (endpoint == NULL)
		goto refuse;
	endpoint->refs++;
	action = ov_vsock_receive(&endpoint->connection, header);
	if (ov_vsock_tx_credit(&endpoint->connection) != 0)
		endpoint->credit_requested = B_FALSE;
	switch (action) {
	case OV_VSOCK_DELIVER_DATA: {
		VERIFY3U(header->len, <=, OV_ILLUMOS_WINDOW - endpoint->used);
		uint32_t tail = (endpoint->head + endpoint->used) % OV_ILLUMOS_WINDOW;
		uint32_t first = MIN(header->len, OV_ILLUMOS_WINDOW - tail);
		bcopy(payload, endpoint->receive + tail, first);
		bcopy(payload + first, endpoint->receive, header->len - first);
		endpoint->used += header->len;
		notify = VS_NOTIFY_READ | VS_NOTIFY_WRITE;
		break;
	}
	case OV_VSOCK_PEER_SHUTDOWN:
		if (header->flags & OV_VSOCK_SHUTDOWN_SEND)
			notify |= VS_NOTIFY_EOF;
		if (header->flags & OV_VSOCK_SHUTDOWN_RECEIVE)
			notify |= VS_NOTIFY_SEND_CLOSED;
		break;
	case OV_VSOCK_SEND_CREDIT:
		endpoint->credit_pending = vs_control(endpoint, OV_VSOCK_CREDIT_UPDATE, 0) != 0;
		notify = VS_NOTIFY_WRITE;
		break;
	case OV_VSOCK_CONNECTION_CLOSED:
		vs_fail(endpoint, ECONNRESET);
		notify = VS_NOTIFY_ERROR;
		break;
	case OV_VSOCK_NONE:
		notify = VS_NOTIFY_WRITE;
		break;
	default:
		vs_refuse(header);
		vs_fail(endpoint, EPROTO);
		notify = VS_NOTIFY_ERROR;
		break;
	}
	cv_broadcast(&endpoint->cv);
	mutex_exit(&vs_lock);
	vs_notify(endpoint, notify);
	vs_put(endpoint);
	return;
refuse:
	vs_refuse(header);
	mutex_exit(&vs_lock);
}

/** @cc [owner:ghuntley,label:recovery;security] illumos-reset-listener-continuation
 * A reset callback MAY retain live listeners only while the validated transport
 * remains ready. Connected and unbound sockets MUST be fenced. A failed
 * transport MUST wake and permanently fence every existing endpoint.
 */
static void
vs_transport_notify(void *reset_arg)
{
	struct vs_socket *held[OV_ILLUMOS_MAX_SOCKETS];
	uint_t count = 0;
	boolean_t reset = reset_arg != NULL;
	mutex_enter(&vs_lock);
	for (struct vs_socket *endpoint = vs_sockets; endpoint != NULL;
	    endpoint = endpoint->next) {
		if ((!reset && endpoint->peer_port == 0) ||
		    (reset && endpoint->listening && endpoint->error == 0 &&
		    viosock_ready()))
			continue;
		if (reset)
			vs_fail(endpoint, ECONNRESET);
		else if (endpoint->connection.phase == OV_VSOCK_ESTABLISHED) {
			if (endpoint->credit_pending)
				endpoint->credit_pending =
				    vs_control(endpoint, OV_VSOCK_CREDIT_UPDATE, 0) != 0;
			if (endpoint->shutdown_pending != 0 &&
			    vs_control(endpoint, OV_VSOCK_SHUTDOWN,
			    endpoint->shutdown_pending) == 0)
				endpoint->shutdown_pending = 0;
		}
		endpoint->refs++;
		held[count++] = endpoint;
		cv_broadcast(&endpoint->cv);
	}
	mutex_exit(&vs_lock);
	for (uint_t n = 0; n < count; n++) {
		vs_notify(held[n], reset ? VS_NOTIFY_ERROR : VS_NOTIFY_WRITE);
		vs_put(held[n]);
	}
}

static void
vs_reset(void *unused)
{
	(void) unused;
	vs_transport_notify((void *)1);
}

static void
vs_writable(void *unused)
{
	(void) unused;
	vs_transport_notify(NULL);
}

static sock_lower_handle_t
vs_create(int family, int type, int protocol, sock_downcalls_t **downcalls,
    uint_t *mode, int *error, int flags, cred_t *cred)
{
	struct vs_socket *endpoint;
	if (family != OV_ILLUMOS_AF_VSOCK || type != SOCK_STREAM || protocol != 0) {
		*error = EPROTONOSUPPORT;
		return (NULL);
	}
	if (crgetzoneid(cred) != GLOBAL_ZONEID || secpolicy_sys_config(cred, B_FALSE) != 0) {
		*error = EACCES;
		return (NULL);
	}
	(void) flags;
	mutex_enter(&vs_lock);
	if (!viosock_ready()) {
		mutex_exit(&vs_lock);
		*error = ENXIO;
		return (NULL);
	}
	endpoint = vs_alloc(KM_NOSLEEP);
	mutex_exit(&vs_lock);
	if (endpoint == NULL) {
		*error = ENOBUFS;
		return (NULL);
	}
	*downcalls = &vs_downcalls;
	*mode = SM_CONNREQUIRED | SM_BYTESTREAM | SM_ACCEPTSUPP | SM_LISTENERR;
	return ((sock_lower_handle_t)endpoint);
}

static void
vs_activate(sock_lower_handle_t lower, sock_upper_handle_t upper,
    sock_upcalls_t *upcalls, int flags, cred_t *cred)
{
	struct vs_socket *endpoint = (struct vs_socket *)lower;
	(void) flags;
	(void) cred;
	mutex_enter(&vs_lock);
	endpoint->upper = upper;
	endpoint->upcalls = upcalls;
	mutex_exit(&vs_lock);
}

static boolean_t
vs_port_busy(uint32_t port)
{
	for (struct vs_socket *endpoint = vs_sockets; endpoint != NULL;
	    endpoint = endpoint->next)
		if (endpoint->bound && endpoint->local_port == port && endpoint->peer_port == 0)
			return (B_TRUE);
	return (B_FALSE);
}

static uint32_t
vs_autoport(void)
{
	for (uint_t n = 0; n <= OV_ILLUMOS_MAX_SOCKETS; n++) {
		uint32_t port = vs_ephemeral++;
		if (vs_ephemeral == VMADDR_PORT_ANY)
			vs_ephemeral = 49152U;
		if (!vs_port_busy(port))
			return (port);
	}
	return (0);
}

static int
vs_bind(sock_lower_handle_t lower, struct sockaddr *address, socklen_t length,
    cred_t *cred)
{
	struct vs_socket *endpoint = (struct vs_socket *)lower;
	struct sockaddr_vm value;
	int error = 0;
	(void) cred;
	if (length != sizeof (value))
		return (EINVAL);
	bcopy(address, &value, sizeof (value));
	if (value.svm_family != OV_ILLUMOS_AF_VSOCK || value.svm_reserved != 0 ||
	    (value.svm_cid != OV_VSOCK_GUEST_CID && value.svm_cid != UINT32_MAX) ||
	    value.svm_zero[0] != 0 || value.svm_zero[1] != 0 || value.svm_zero[2] != 0 || value.svm_zero[3] != 0)
		return (EADDRNOTAVAIL);
	mutex_enter(&vs_lock);
	if (endpoint->error != 0)
		error = endpoint->error;
	else if (endpoint->bound || endpoint->closing)
		error = EINVAL;
	else if (value.svm_port == 0)
		error = EADDRNOTAVAIL;
	else if (value.svm_port != VMADDR_PORT_ANY && vs_port_busy(value.svm_port))
		error = EADDRINUSE;
	else {
		endpoint->local_port = value.svm_port == VMADDR_PORT_ANY ?
		    vs_autoport() : value.svm_port;
		endpoint->bound = B_TRUE;
	}
	mutex_exit(&vs_lock);
	return (error);
}

static int
vs_listen(sock_lower_handle_t lower, int backlog, cred_t *cred)
{
	struct vs_socket *endpoint = (struct vs_socket *)lower;
	(void) cred;
	mutex_enter(&vs_lock);
	if (endpoint->error != 0 || endpoint->closing || endpoint->peer_port != 0) {
		int error = endpoint->error != 0 ? endpoint->error : EINVAL;
		mutex_exit(&vs_lock);
		return (error);
	}
	if (!endpoint->bound) {
		endpoint->local_port = vs_autoport();
		endpoint->bound = B_TRUE;
	}
	endpoint->listening = B_TRUE;
	endpoint->refs++;
	sock_upper_handle_t upper = endpoint->upper;
	sock_upcalls_t *upcalls = endpoint->upcalls;
	mutex_exit(&vs_lock);
	upcalls->su_opctl(upper, SOCK_OPCTL_ENAB_ACCEPT,
	    MAX(1, MIN(backlog, (int)OV_ILLUMOS_MAX_SOCKETS)));
	vs_put(endpoint);
	return (0);
}

/** @cc [owner:ghuntley,label:protocol;recovery] illumos-accept-after-response
 * Accept MUST wait until the connection RESPONSE has been submitted before
 * returning the child to user code. An immediate application close MUST NOT
 * race ahead of that handshake. A reset, closed listener or interrupted wait
 * MUST refuse instead of publishing an unestablished socket.
 */
static int
vs_accept(sock_lower_handle_t lower, sock_lower_handle_t child,
    sock_upper_handle_t upper, cred_t *cred)
{
	struct vs_socket *endpoint = (struct vs_socket *)child;
	struct vs_socket *listener = (struct vs_socket *)lower;
	(void) cred;
	mutex_enter(&vs_lock);
	while (endpoint->handshake && !endpoint->closing && endpoint->error == 0 &&
	    !listener->closing && listener->error == 0 && listener->listening) {
		if (cv_wait_sig(&endpoint->cv, &vs_lock) == 0) {
			mutex_exit(&vs_lock);
			return (EINTR);
		}
	}
	if (endpoint->closing || endpoint->error != 0 ||
	    endpoint->connection.phase != OV_VSOCK_ESTABLISHED ||
	    listener->closing || listener->error != 0 || !listener->listening) {
		mutex_exit(&vs_lock);
		return (ECONNRESET);
	}
	endpoint->upper = upper;
	mutex_exit(&vs_lock);
	return (0);
}

static int
vs_name(sock_lower_handle_t lower, struct sockaddr *address,
    socklen_t *length, boolean_t peer)
{
	struct vs_socket *endpoint = (struct vs_socket *)lower;
	struct sockaddr_vm value = { .svm_family = OV_ILLUMOS_AF_VSOCK };
	mutex_enter(&vs_lock);
	if (peer && endpoint->peer_port == 0) {
		mutex_exit(&vs_lock);
		return (ENOTCONN);
	}
	value.svm_cid = peer ? OV_VSOCK_HOST_CID : OV_VSOCK_GUEST_CID;
	value.svm_port = peer ? endpoint->peer_port : endpoint->local_port;
	mutex_exit(&vs_lock);
	bcopy(&value, address, MIN(*length, sizeof (value)));
	*length = sizeof (value);
	return (0);
}

static int
vs_peername(sock_lower_handle_t lower, struct sockaddr *address,
    socklen_t *length, cred_t *cred)
{
	(void) cred;
	return (vs_name(lower, address, length, B_TRUE));
}

static int
vs_sockname(sock_lower_handle_t lower, struct sockaddr *address,
    socklen_t *length, cred_t *cred)
{
	(void) cred;
	return (vs_name(lower, address, length, B_FALSE));
}

static int
vs_wait(struct vs_socket *endpoint, clock_t deadline, boolean_t nonblocking)
{
	int result;
	if (nonblocking)
		return (EAGAIN);
	if (deadline != 0) {
		result = cv_timedwait_sig(&endpoint->cv, &vs_lock, deadline);
		return (result == -1 ? EAGAIN : result == 0 ? EINTR : 0);
	}
	return (cv_wait_sig(&endpoint->cv, &vs_lock) == 0 ? EINTR : 0);
}

/** @cc [owner:ghuntley,label:security;protocol] illumos-vsock-credit-on-user-read
 * Consumed credit MUST advance only by bytes actually copied from the bounded
 * receive ring to the application. MSG_PEEK MUST NOT remove bytes or grant
 * credit. Copy faults MUST preserve the unread suffix, and a socket or transport
 * reset MUST wake blocked readers and writers without reusing the old stream.
 */
static int
vs_recv(sock_lower_handle_t lower, uio_t *uio, struct nmsghdr *message, cred_t *cred)
{
	struct vs_socket *endpoint = (struct vs_socket *)lower;
	boolean_t nonblocking = (uio->uio_fmode & (FNDELAY | FNONBLOCK)) != 0 ||
	    (message->msg_flags & MSG_DONTWAIT) != 0;
	boolean_t peek = (message->msg_flags & MSG_PEEK) != 0;
	boolean_t waitall = (message->msg_flags & MSG_WAITALL) != 0;
	ssize_t initial = uio->uio_resid;
	uint32_t peeked = 0;
	int error = 0;
	(void) cred;
	if (message->msg_flags & MSG_OOB)
		return (EOPNOTSUPP);
	message->msg_namelen = message->msg_controllen = 0;
	message->msg_flags = 0;
	mutex_enter(&vs_lock);
	endpoint->refs++;
	clock_t deadline = endpoint->receive_timeout == 0 ? 0 :
	    ddi_get_lbolt() + endpoint->receive_timeout;
	while (endpoint->reading && !endpoint->closing && error == 0)
		error = vs_wait(endpoint, deadline, nonblocking);
	if (error != 0)
		goto done;
	if (endpoint->closing || endpoint->peer_port == 0) {
		error = endpoint->error != 0 ? endpoint->error : ENOTCONN;
		goto done;
	}
	endpoint->reading = B_TRUE;
	while (uio->uio_resid != 0) {
		if (endpoint->connection.local_shutdown & OV_VSOCK_SHUTDOWN_RECEIVE)
			break;
		uint32_t available = endpoint->used - peeked;
		if (available == 0) {
			if (endpoint->closing || endpoint->connection.phase == OV_VSOCK_CLOSED ||
			    endpoint->connection.local_shutdown & OV_VSOCK_SHUTDOWN_RECEIVE ||
			    endpoint->connection.peer_shutdown & OV_VSOCK_SHUTDOWN_SEND) {
				error = endpoint->error;
				break;
			}
			if (uio->uio_resid != initial && (!waitall || peek))
				break;
			error = vs_wait(endpoint, deadline, nonblocking);
			if (error != 0)
				break;
			continue;
		}
		uint32_t offset = (endpoint->head + peeked) % OV_ILLUMOS_WINDOW;
		uint32_t bytes = MIN(available, OV_ILLUMOS_WINDOW - offset);
		bytes = MIN(bytes, uio->uio_resid);
		ssize_t before = uio->uio_resid;
		mutex_exit(&vs_lock);
		error = uiomove(endpoint->receive + offset, bytes, UIO_READ, uio);
		mutex_enter(&vs_lock);
		uint32_t copied = before - uio->uio_resid;
		if (peek)
			peeked += copied;
		else {
			endpoint->head = (endpoint->head + copied) % OV_ILLUMOS_WINDOW;
			endpoint->used -= copied;
			if (endpoint->connection.phase == OV_VSOCK_ESTABLISHED) {
				VERIFY(ov_vsock_consumed(&endpoint->connection, copied) == OV_VSOCK_OK);
				endpoint->credit_pending =
				    vs_control(endpoint, OV_VSOCK_CREDIT_UPDATE, 0) != 0;
			}
		}
		if (error != 0 || copied == 0)
			break;
	}
	endpoint->reading = B_FALSE;
	if (endpoint->connection.local_shutdown & OV_VSOCK_SHUTDOWN_RECEIVE) {
		endpoint->used = 0;
		endpoint->head = 0;
	}
	cv_broadcast(&endpoint->cv);
done:
	mutex_exit(&vs_lock);
	vs_put(endpoint);
	return (uio->uio_resid != initial ? 0 : error);
}

static int
vs_send(sock_lower_handle_t lower, uio_t *uio, struct nmsghdr *message, cred_t *cred)
{
	struct vs_socket *endpoint = (struct vs_socket *)lower;
	boolean_t nonblocking = (uio->uio_fmode & (FNDELAY | FNONBLOCK)) != 0 ||
	    (message->msg_flags & MSG_DONTWAIT) != 0;
	ssize_t initial = uio->uio_resid;
	int error = 0;
	(void) cred;
	if (message->msg_flags & MSG_OOB || message->msg_controllen != 0)
		return (EOPNOTSUPP);
	mutex_enter(&vs_lock);
	endpoint->refs++;
	clock_t deadline = endpoint->send_timeout == 0 ? 0 :
	    ddi_get_lbolt() + endpoint->send_timeout;
	while (endpoint->sending && !endpoint->closing && error == 0)
		error = vs_wait(endpoint, deadline, nonblocking);
	if (error != 0)
		goto done;
	if (endpoint->closing) {
		error = endpoint->error != 0 ? endpoint->error : EPIPE;
		goto done;
	}
	endpoint->sending = B_TRUE;
	while (uio->uio_resid != 0) {
		if (endpoint->closing || endpoint->connection.phase != OV_VSOCK_ESTABLISHED ||
		    endpoint->connection.local_shutdown & OV_VSOCK_SHUTDOWN_SEND ||
		    endpoint->connection.peer_shutdown & OV_VSOCK_SHUTDOWN_RECEIVE) {
			error = endpoint->error != 0 ? endpoint->error : EPIPE;
			break;
		}
		uint32_t bytes = MIN(ov_vsock_tx_credit(&endpoint->connection),
		    OV_VSOCK_MAX_PAYLOAD);
		bytes = MIN(bytes, uio->uio_resid);
		if (endpoint->handshake || bytes == 0) {
			if (!endpoint->handshake && !endpoint->credit_requested)
				endpoint->credit_requested =
				    vs_control(endpoint, OV_VSOCK_CREDIT_REQUEST, 0) == 0;
			error = vs_wait(endpoint, deadline, nonblocking);
			if (error != 0)
				break;
			continue;
		}
		size_t copied = 0;
		mutex_exit(&vs_lock);
		error = uiocopy(endpoint->transmit, bytes, UIO_WRITE, uio, &copied);
		mutex_enter(&vs_lock);
		if (error != 0)
			break;
		/* uiocopy drops vs_lock: revalidate every condition used by sent(). */
		if (endpoint->closing || endpoint->connection.phase != OV_VSOCK_ESTABLISHED ||
		    endpoint->connection.local_shutdown & OV_VSOCK_SHUTDOWN_SEND ||
		    endpoint->connection.peer_shutdown & OV_VSOCK_SHUTDOWN_RECEIVE) {
			error = endpoint->error != 0 ? endpoint->error : EPIPE;
			break;
		}
		if (copied == 0) {
			error = EFAULT;
			break;
		}
		if (copied > ov_vsock_tx_credit(&endpoint->connection))
			continue;
		struct ov_vsock_header header = vs_header(endpoint, OV_VSOCK_RW, copied, 0);
		error = viosock_xmit(&header, endpoint->transmit);
		if (error == EAGAIN) {
			error = vs_wait(endpoint, deadline, nonblocking);
			if (error != 0)
				break;
			continue;
		}
		if (error != 0)
			break;
		VERIFY(ov_vsock_sent(&endpoint->connection, copied) == OV_VSOCK_OK);
		uioskip(uio, copied);
	}
	endpoint->sending = B_FALSE;
	cv_broadcast(&endpoint->cv);
done:
	mutex_exit(&vs_lock);
	vs_put(endpoint);
	return (uio->uio_resid != initial ? 0 : error);
}

static short
vs_poll(sock_lower_handle_t lower, short requested, int any, cred_t *cred)
{
	struct vs_socket *endpoint = (struct vs_socket *)lower;
	short result = 0;
	(void) requested;
	(void) any;
	(void) cred;
	mutex_enter(&vs_lock);
	if (endpoint->used != 0 ||
	    endpoint->connection.local_shutdown & OV_VSOCK_SHUTDOWN_RECEIVE ||
	    endpoint->connection.peer_shutdown & OV_VSOCK_SHUTDOWN_SEND)
		result |= POLLIN | POLLRDNORM;
	if (!endpoint->handshake && ov_vsock_tx_credit(&endpoint->connection) != 0)
		result |= POLLOUT | POLLWRNORM;
	if (endpoint->closing || endpoint->connection.phase == OV_VSOCK_CLOSED)
		result |= POLLHUP;
	if (endpoint->error != 0)
		result |= POLLERR;
	mutex_exit(&vs_lock);
	return (result);
}

static int
vs_shutdown(sock_lower_handle_t lower, int how, cred_t *cred)
{
	struct vs_socket *endpoint = (struct vs_socket *)lower;
	uint32_t flags;
	int error;
	(void) cred;
	if (how < SHUT_RD || how > SHUT_RDWR)
		return (EINVAL);
	flags = how == SHUT_RD ? OV_VSOCK_SHUTDOWN_RECEIVE :
	    how == SHUT_WR ? OV_VSOCK_SHUTDOWN_SEND : 3U;
	mutex_enter(&vs_lock);
	if (ov_vsock_shutdown(&endpoint->connection, flags) != OV_VSOCK_OK)
		error = ENOTCONN;
	else {
		/* The active reader owns any unlocked uiomove source until it returns. */
		if (!endpoint->reading && flags & OV_VSOCK_SHUTDOWN_RECEIVE) {
			endpoint->used = 0;
			endpoint->head = 0;
		}
		endpoint->shutdown_pending |= flags;
		error = vs_control(endpoint, OV_VSOCK_SHUTDOWN, endpoint->shutdown_pending);
		if (error == 0)
			endpoint->shutdown_pending = 0;
		else if (error == EAGAIN)
			error = 0; /* The writable callback retries the bounded control. */
		cv_broadcast(&endpoint->cv);
	}
	mutex_exit(&vs_lock);
	return (error);
}

/** @cc [owner:ghuntley,label:security;build] illumos-vsock-loaded-build-identity
 * The read-only AF_VSOCK/VSOCK_SO_BUILD_ID option MUST return exactly the loaded
 * transport's 64-hex build-input token plus NUL only when both modules match,
 * the transport is ready and the socket is unfenced. A short buffer, mismatch,
 * closed socket or other option MUST refuse; no file-derived value may substitute.
 */
static int
vs_getsockopt(sock_lower_handle_t lower, int level, int option, void *value,
    socklen_t *length, cred_t *cred)
{
	struct vs_socket *endpoint = (struct vs_socket *)lower;
	int error = 0;
	(void) cred;
	if (level != AF_VSOCK || option != VSOCK_SO_BUILD_ID)
		return (ENOPROTOOPT);
	if (*length < VSOCK_BUILD_ID_SIZE)
		return (EMSGSIZE);
	mutex_enter(&vs_lock);
	if (endpoint->error != 0 || endpoint->closing || !viosock_ready())
		error = ECONNRESET;
	else if (bcmp(viosock_build_id(), OV_VSOCK_BUILD_ID, VSOCK_BUILD_ID_SIZE) != 0)
		error = ESTALE;
	else {
		bcopy(viosock_build_id(), value, VSOCK_BUILD_ID_SIZE);
		*length = VSOCK_BUILD_ID_SIZE;
	}
	mutex_exit(&vs_lock);
	return (error);
}

static int
vs_setsockopt(sock_lower_handle_t lower, int level, int option, const void *value,
    socklen_t length, cred_t *cred)
{
	struct vs_socket *endpoint = (struct vs_socket *)lower;
	(void) cred;
	if (level == AF_VSOCK && option == VSOCK_SO_BUILD_ID)
		return (EOPNOTSUPP);
	if (level != SOL_SOCKET)
		return (ENOPROTOOPT);
	if (option == SO_RCVTIMEO || option == SO_SNDTIMEO) {
		struct timeval timeout;
		if (length != sizeof (timeout))
			return (EINVAL);
		bcopy(value, &timeout, sizeof (timeout));
		if (timeout.tv_sec < 0 || timeout.tv_sec > 3600 ||
		    timeout.tv_usec < 0 || timeout.tv_usec >= 1000000)
			return (EINVAL);
		clock_t ticks = drv_usectohz(timeout.tv_sec * 1000000 + timeout.tv_usec);
		mutex_enter(&vs_lock);
		if (option == SO_RCVTIMEO)
			endpoint->receive_timeout = ticks;
		else
			endpoint->send_timeout = ticks;
		mutex_exit(&vs_lock);
		return (0);
	}
	return (ENOPROTOOPT);
}

static int
vs_ioctl(sock_lower_handle_t lower, int command, intptr_t argument, int mode,
    int32_t *result, cred_t *cred)
{
	struct vs_socket *endpoint = (struct vs_socket *)lower;
	int bytes;
	(void) result;
	(void) cred;
	if (command != FIONREAD)
		return (ENOTTY);
	mutex_enter(&vs_lock);
	bytes = endpoint->used;
	mutex_exit(&vs_lock);
	return (ddi_copyout(&bytes, (void *)argument, sizeof (bytes), mode) != 0 ? EFAULT : 0);
}

/** @cc [owner:ghuntley,label:recovery;protocol] illumos-listener-close-wakes-accept
 * Closing a listener MUST publish its closed state and wake pending-handshake
 * children on its port under vs_lock. A child waiting in sd_accept MUST refuse
 * without depending on the connection callback completing or another interrupt.
 */
static int
vs_close(sock_lower_handle_t lower, int flags, cred_t *cred)
{
	struct vs_socket *endpoint = (struct vs_socket *)lower;
	boolean_t asynchronous;
	boolean_t listener;
	(void) flags;
	(void) cred;
	mutex_enter(&vs_lock);
	listener = endpoint->listening;
	vs_remove(endpoint);
	if (endpoint->connection.phase == OV_VSOCK_ESTABLISHED)
		(void) vs_control(endpoint, OV_VSOCK_RST, 0);
	vs_fail(endpoint, ECONNRESET);
	endpoint->closing = B_TRUE;
	/* sd_accept waits on the child CV while also observing listener state. */
	if (listener) {
		for (struct vs_socket *child = vs_sockets; child != NULL;
		    child = child->next) {
			if (child->local_port == endpoint->local_port && child->handshake)
				cv_broadcast(&child->cv);
		}
	}
	asynchronous = endpoint->refs > 1;
	endpoint->async_close = asynchronous;
	mutex_exit(&vs_lock);
	vs_put(endpoint);
	return (asynchronous ? EINPROGRESS : 0);
}

static sock_downcalls_t vs_downcalls = {
	.sd_activate = vs_activate,
	.sd_accept = vs_accept,
	.sd_bind = vs_bind,
	.sd_listen = vs_listen,
	.sd_connect = sock_connect_notsupp,
	.sd_getpeername = vs_peername,
	.sd_getsockname = vs_sockname,
	.sd_getsockopt = vs_getsockopt,
	.sd_setsockopt = vs_setsockopt,
	.sd_send_uio = vs_send,
	.sd_recv_uio = vs_recv,
	.sd_poll = vs_poll,
	.sd_shutdown = vs_shutdown,
	.sd_clr_flowctrl = sock_clr_flowctrl_notsupp,
	.sd_ioctl = vs_ioctl,
	.sd_close = vs_close
};

static smod_reg_t vs_registration = {
	SOCKMOD_VERSION, "sockvsock", SOCK_UC_VERSION, SOCK_DC_VERSION,
	vs_create, NULL
};
static struct modlsockmod vs_modlsockmod = {
	&mod_sockmodops, "Host-only bounded vsock stream sockets", &vs_registration
};
static struct modlinkage vs_modlinkage = {
	MODREV_1, { &vs_modlsockmod, NULL }
};

int
_init(void)
{
	int error;
	mutex_init(&vs_lock, NULL, MUTEX_DRIVER, NULL);
	error = viosock_subscribe(vs_receive, vs_reset, vs_writable, NULL);
	if (error == 0) {
		error = mod_install(&vs_modlinkage);
		if (error != 0)
			viosock_unsubscribe(NULL);
	}
	if (error != 0)
		mutex_destroy(&vs_lock);
	return (error);
}

int
_fini(void)
{
	int error = mod_remove(&vs_modlinkage);
	if (error == 0) {
		viosock_unsubscribe(NULL);
		mutex_destroy(&vs_lock);
	}
	return (error);
}

int
_info(struct modinfo *info)
{
	return (mod_info(&vs_modlinkage, info));
}

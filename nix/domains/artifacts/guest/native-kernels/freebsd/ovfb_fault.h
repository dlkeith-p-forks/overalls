/* SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Overalls contributors.
 *
 * Test-only received-frame injection. This file is compiled only into the
 * separately identified GENERIC-OVERALLS-FAULT kernel; production kernels do
 * not define OVFB_FAULT_INJECTION and therefore expose no injection OID.
 */
#ifndef OVFB_FAULT_INJECTION
#error "ovfb_fault.h is only for the fault-injection kernel"
#endif

static uint8_t ovfb_fault_frame[OV_VSOCK_HEADER_BYTES + OV_VSOCK_MAX_PAYLOAD];

SYSCTL_UINT(_debug, OID_AUTO, overalls_vsock_fault_injection, CTLFLAG_RD,
    SYSCTL_NULL_UINT_PTR, 1, "Overalls test-only vsock frame injection kernel");

/** @cc [owner:ghuntley,label:verification;security] freebsd-fault-frame-injection
 * A privileged write MUST pass exactly one raw frame through the same
 * ovfb_receive path as a device-delivered receive buffer, under the domain
 * lock that the receive task holds. Frames the common decoder refuses MUST
 * return EBADMSG without reaching socket state; decoded frames return 0.
 * The frame buffer MUST be cleared after each injection.
 */
static int
ovfb_fault_inject(SYSCTL_HANDLER_ARGS)
{
    struct ov_vsock_header header;
    struct ovfb_packet packet;
    size_t length;
    int error;

    if (req->newptr == NULL)
        return (EINVAL);
    error = priv_check(req->td, PRIV_DRIVER);
    if (error != 0)
        return (error);
    length = req->newlen - req->newidx;
    if (length < OV_VSOCK_HEADER_BYTES || length > sizeof(ovfb_fault_frame))
        return (EMSGSIZE);
    sx_xlock(&ovfb_domain_lock);
    if (ovfb_device == NULL || !ovfb_device->ready) {
        sx_xunlock(&ovfb_domain_lock);
        return (ENXIO);
    }
    error = SYSCTL_IN(req, ovfb_fault_frame, length);
    if (error == 0) {
        if (ov_vsock_decode(ovfb_fault_frame, length, &header) != OV_VSOCK_OK) {
            error = EBADMSG;
        } else {
            bzero(&packet, sizeof(packet));
            packet.data = ovfb_fault_frame;
            ovfb_receive(&packet, (uint32_t)length);
        }
    }
    explicit_bzero(ovfb_fault_frame, sizeof(ovfb_fault_frame));
    sx_xunlock(&ovfb_domain_lock);
    return (error);
}

SYSCTL_PROC(_debug, OID_AUTO, overalls_vsock_inject,
    CTLTYPE_OPAQUE | CTLFLAG_WR | CTLFLAG_MPSAFE, NULL, 0, ovfb_fault_inject,
    "S", "Overalls test-only: inject one raw received vsock frame");

/** @cc [owner:ghuntley,label:verification;recovery] freebsd-fault-reset-race
 * A privileged write of 1 MUST raise the same pending-reset condition as an
 * unexpected device configuration change through ovfb_config_change, so the
 * real receive task observes an invalid reset, fences every socket and stops
 * the device. Repeated writes MAY race live traffic and each other; they MUST
 * NOT bypass the task's domain lock or touch socket state directly.
 */
static int
ovfb_fault_reset(SYSCTL_HANDLER_ARGS)
{
    int value = 0;
    int error;

    error = sysctl_handle_int(oidp, &value, 0, req);
    if (error != 0 || req->newptr == NULL)
        return (error);
    if (value != 1)
        return (EINVAL);
    error = priv_check(req->td, PRIV_DRIVER);
    if (error != 0)
        return (error);
    sx_xlock(&ovfb_domain_lock);
    if (ovfb_device == NULL) {
        sx_xunlock(&ovfb_domain_lock);
        return (ENXIO);
    }
    error = ovfb_config_change(ovfb_device->dev);
    sx_xunlock(&ovfb_domain_lock);
    return (error);
}

SYSCTL_PROC(_debug, OID_AUTO, overalls_vsock_inject_reset,
    CTLTYPE_INT | CTLFLAG_WR | CTLFLAG_MPSAFE, NULL, 0, ovfb_fault_reset,
    "I", "Overalls test-only: raise an unexpected device reset");

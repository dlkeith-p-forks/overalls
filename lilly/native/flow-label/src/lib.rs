#![deny(unsafe_code)]
#![doc = "Exact read-only kernel flow lookup; stdout is a private fixed-size protocol."]

use std::ffi::{OsStr, OsString};

pub const EXIT_FAILED: u8 = 1;

/// Why an exact read failed: transport, capability or inventory boundary.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FlowError {
    Unavailable,
}

/// Attribute numbers from libnetfilter_conntrack.h (enum nf_conntrack_attr).
pub const ATTR_ORIG_IPV4_SRC: u8 = 0;
pub const ATTR_ORIG_IPV4_DST: u8 = 1;
pub const ATTR_ORIG_PORT_SRC: u8 = 8;
pub const ATTR_ORIG_PORT_DST: u8 = 9;
pub const ATTR_L3PROTO: u8 = 15;
pub const ATTR_L4PROTO: u8 = 17;
pub const ATTR_CONNLABELS: u8 = 66;
/// NFNL_SUBSYS_CTNETLINK.
pub const CONNTRACK_SUBSYSTEM: u8 = 1;
/// NFCT_T_NEW | NFCT_T_UPDATE | NFCT_T_DESTROY (7).
pub const NFCT_T_ALL: i32 = 7;
/// nf_conntrack_query NFCT_Q_GET (3).
pub const NFCT_Q_GET: u32 = 3;
/// NFCT_CB_FAILURE (-1).
pub const CB_FAILURE: i32 = -1;
/// NFCT_CB_CONTINUE (1).
pub const CB_CONTINUE: i32 = 1;

/// Canonical dotted-quad IPv4 with exact parse/render round-trip: the C
/// predecessor compared the input with its own canonical form byte for byte.
/// The value keeps inet_pton's in-memory layout (network byte order), which
/// nfct_set_attr_u32 and the kernel record use; a host-order integer would
/// query a byte-reversed address and never match a live flow.
pub fn address(text: &OsStr) -> Option<u32> {
    let text = text.to_str()?;
    let addr: std::net::Ipv4Addr = text.parse().ok()?;
    if addr.to_string() == text {
        Some(u32::from_ne_bytes(addr.octets()))
    } else {
        None
    }
}

/// Decimal port: nonempty, ≤5 digits, no leading zero, 1..=65535, stored in
/// network byte order so direct comparison against the kernel record works.
pub fn port(text: &OsStr) -> Option<u16> {
    let text = text.to_str()?;
    let bytes = text.as_bytes();
    if bytes.is_empty() || bytes.len() > 5 || bytes[0] == b'0' {
        return None;
    }
    if !bytes.iter().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let value: u16 = text.parse().ok()?;
    if value == 0 {
        return None;
    }
    Some(value.to_be())
}

/// @cc [owner:ghuntley,label:security;capacity] native-flow-read-only-bounded
/// The helper MUST issue only a single exact conntrack GET in its inherited
/// namespace, with canonical tuple arguments and a two-second process
/// deadline. It MUST NOT dump, create, update or delete conntrack entries or
/// change namespace.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Query {
    pub source: u32,
    pub destination: u32,
    pub sport: u16,
    pub dport: u16,
}

pub fn parse_cli(arguments: &[OsString]) -> Option<Query> {
    let [source, sport, destination, dport] = arguments else {
        return None;
    };
    Some(Query {
        source: address(source)?,
        sport: port(sport)?,
        destination: address(destination)?,
        dport: port(dport)?,
    })
}

/// Connlabel bits as returned by the kernel; Lilly requires the bit-127 marker
/// and renders the label big-endian.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Labels([u8; 16]);

impl Labels {
    fn zero() -> Self {
        Self([0; 16])
    }

    fn set(&mut self, bit: u32) {
        if bit < 128 {
            let byte = 15 - (bit / 8) as usize;
            self.0[byte] |= 1 << (bit % 8);
        }
    }

    pub fn to_hex(&self) -> String {
        let mut out = String::with_capacity(32);
        for byte in self.0 {
            out.push(char::from_digit(u32::from(byte >> 4), 16).expect("hex"));
            out.push(char::from_digit(u32::from(byte & 0x0f), 16).expect("hex"));
        }
        out
    }
}

/// One exact-lookup outcome.
pub struct Lookup {
    pub query: Query,
    pub label: Option<Labels>,
    pub count: u32,
}

/// The kernel boundary: one connection handle, one ct, one callback registry.
#[allow(unsafe_code)]
mod nct {
    use super::{Labels, Lookup};
    use super::{
        ATTR_CONNLABELS, ATTR_L3PROTO, ATTR_L4PROTO, ATTR_ORIG_IPV4_DST, ATTR_ORIG_IPV4_SRC,
        ATTR_ORIG_PORT_DST, ATTR_ORIG_PORT_SRC, CONNTRACK_SUBSYSTEM,
    };
    use super::{CB_CONTINUE, CB_FAILURE};
    use std::os::fd::RawFd;

    #[repr(C)]
    pub struct Handle {
        _private: [u8; 0],
    }

    #[repr(C)]
    pub struct Ct {
        _private: [u8; 0],
    }

    #[repr(C)]
    pub struct Bitmask {
        _private: [u8; 0],
    }

    type Callback = extern "C" fn(libc::c_int, *mut Ct, *mut libc::c_void) -> libc::c_int;

    #[link(name = "netfilter_conntrack")]
    unsafe extern "C" {
        pub fn nfct_open(subsys: u8, events: libc::c_uint) -> *mut Handle;
        pub fn nfct_close(handle: *mut Handle);
        pub fn nfct_new() -> *mut Ct;
        pub fn nfct_destroy(ct: *mut Ct);
        pub fn nfct_fd(handle: *const Handle) -> RawFd;
        pub fn nfct_set_attr_u8(ct: *mut Ct, attr: u8, value: u8);
        pub fn nfct_set_attr_u16(ct: *mut Ct, attr: u8, value: u16);
        pub fn nfct_set_attr_u32(ct: *mut Ct, attr: u8, value: u32);
        pub fn nfct_attr_is_set(ct: *const Ct, attr: u8) -> libc::c_int;
        pub fn nfct_get_attr_u8(ct: *mut Ct, attr: u8) -> u8;
        pub fn nfct_get_attr_u16(ct: *mut Ct, attr: u8) -> u16;
        pub fn nfct_get_attr_u32(ct: *mut Ct, attr: u8) -> u32;
        pub fn nfct_get_attr(ct: *mut Ct, attr: u8) -> *const Bitmask;
        pub fn nfct_bitmask_maxbit(bits: *const Bitmask) -> libc::c_int;
        pub fn nfct_bitmask_test_bit(bits: *const Bitmask, bit: libc::c_uint) -> libc::c_int;
        pub fn nfct_callback_register(
            handle: *mut Handle,
            message_type: libc::c_int,
            cb: Callback,
            data: *mut libc::c_void,
        ) -> libc::c_int;
        pub fn nfct_query(handle: *mut Handle, query: u32, ct: *mut Ct) -> libc::c_int;
    }

    pub(super) struct HandleRef(pub *mut Handle);

    impl HandleRef {
        pub(super) fn fd(&self) -> RawFd {
            unsafe { nfct_fd(self.0) }
        }
    }

    impl Drop for HandleRef {
        fn drop(&mut self) {
            unsafe { nfct_close(self.0) }
        }
    }

    pub(super) struct CtRef(pub *mut Ct);

    impl Drop for CtRef {
        fn drop(&mut self) {
            unsafe { nfct_destroy(self.0) }
        }
    }

    pub(super) fn open() -> Option<HandleRef> {
        let handle = unsafe { nfct_open(CONNTRACK_SUBSYSTEM, 0) };
        if handle.is_null() {
            None
        } else {
            Some(HandleRef(handle))
        }
    }

    pub(super) fn new_ct() -> Option<CtRef> {
        let ct = unsafe { nfct_new() };
        if ct.is_null() {
            None
        } else {
            Some(CtRef(ct))
        }
    }

    pub(super) fn set_query_tuple(ct: &mut CtRef, query: &super::Query) {
        unsafe {
            nfct_set_attr_u8(ct.0, ATTR_L3PROTO, libc::AF_INET as u8);
            nfct_set_attr_u8(ct.0, ATTR_L4PROTO, libc::IPPROTO_TCP as u8);
            nfct_set_attr_u32(ct.0, ATTR_ORIG_IPV4_SRC, query.source);
            nfct_set_attr_u32(ct.0, ATTR_ORIG_IPV4_DST, query.destination);
            nfct_set_attr_u16(ct.0, ATTR_ORIG_PORT_SRC, query.sport);
            nfct_set_attr_u16(ct.0, ATTR_ORIG_PORT_DST, query.dport);
        }
    }

    pub(super) fn register_get(
        handle: &mut HandleRef,
        callback: Callback,
        lookup: &mut Lookup,
    ) -> bool {
        let status = unsafe {
            nfct_callback_register(
                handle.0,
                super::NFCT_T_ALL,
                callback,
                lookup as *mut Lookup as *mut libc::c_void,
            )
        };
        status >= 0
    }

    pub(super) fn query_get(handle: &mut HandleRef, ct: &mut CtRef) -> bool {
        let result = unsafe { nfct_query(handle.0, super::NFCT_Q_GET, ct.0) };
        result >= 0
    }

    /// @cc [owner:ghuntley,label:security] native-flow-callback-confined
    /// The C callback's pointer surface is confined here: the scalar reads map
    /// into typed values before any policy decision; the write-out accumulates
    /// into Labels only. No argument or network data flows elsewhere.
    extern "C" fn collect(
        _message_type: libc::c_int,
        ct: *mut Ct,
        data: *mut libc::c_void,
    ) -> libc::c_int {
        let lookup = unsafe { &mut *(data as *mut Lookup) };
        lookup.count += 1;
        if lookup.count != 1 {
            return CB_FAILURE;
        }
        for attr in [
            ATTR_L3PROTO,
            ATTR_L4PROTO,
            ATTR_ORIG_IPV4_SRC,
            ATTR_ORIG_IPV4_DST,
            ATTR_ORIG_PORT_SRC,
            ATTR_ORIG_PORT_DST,
            ATTR_CONNLABELS,
        ] {
            if unsafe { nfct_attr_is_set(ct, attr) } != 1 {
                return CB_FAILURE;
            }
        }
        if unsafe { nfct_get_attr_u8(ct, ATTR_L3PROTO) } != libc::AF_INET as u8
            || unsafe { nfct_get_attr_u8(ct, ATTR_L4PROTO) } != libc::IPPROTO_TCP as u8
            || unsafe { nfct_get_attr_u32(ct, ATTR_ORIG_IPV4_SRC) } != lookup.query.source
            || unsafe { nfct_get_attr_u32(ct, ATTR_ORIG_IPV4_DST) } != lookup.query.destination
            || unsafe { nfct_get_attr_u16(ct, ATTR_ORIG_PORT_SRC) } != lookup.query.sport
            || unsafe { nfct_get_attr_u16(ct, ATTR_ORIG_PORT_DST) } != lookup.query.dport
        {
            return CB_FAILURE;
        }
        let bits = unsafe { nfct_get_attr(ct, ATTR_CONNLABELS) };
        if bits.is_null() {
            return CB_FAILURE;
        }
        if unsafe { nfct_bitmask_maxbit(bits) } < 127
            || unsafe { nfct_bitmask_test_bit(bits, 127) } != 1
        {
            return CB_FAILURE;
        }
        let mut label = Labels::zero();
        for bit in 0..128_u32 {
            if unsafe { nfct_bitmask_test_bit(bits, bit) } == 1 {
                label.set(bit);
            }
        }
        lookup.label = Some(label);
        CB_CONTINUE
    }

    pub(super) const COLLECT: Callback = collect;

    /// fd 0/1/2-clone for setsockopt works through raw numbers; routing the
    /// handle-borrowed descriptor through the typed sockopt call keeps the
    /// lifetime with the netlink handle.
    pub(super) fn set_recv_timeout(
        handle: &HandleRef,
        seconds: u64,
    ) -> Result<(), rustix::io::Errno> {
        let fd = handle.fd();
        if fd < 0 {
            return Err(rustix::io::Errno::BADF);
        }
        let borrowed = unsafe { std::os::fd::BorrowedFd::borrow_raw(fd) };
        rustix::net::sockopt::set_socket_timeout(
            borrowed,
            rustix::net::sockopt::Timeout::Recv,
            Some(std::time::Duration::from_secs(seconds)),
        )
    }
}

/// @cc [owner:ghuntley,label:security] native-flow-exact-kernel-label
/// A result MUST match the complete requested IPv4 TCP original tuple and
/// carry Lilly's bit-127 label marker. Missing, ambiguous or mismatched
/// results MUST produce no stdout. Output MUST contain only the 128-bit label,
/// never flow data.
pub fn lookup(query: Query) -> Result<Option<Labels>, FlowError> {
    let mut handle = nct::open().ok_or(FlowError::Unavailable)?;
    nct::set_recv_timeout(&handle, 1).map_err(|_| FlowError::Unavailable)?;
    label_shim::alarm_after_two_seconds();
    let mut ct = nct::new_ct().ok_or(FlowError::Unavailable)?;
    nct::set_query_tuple(&mut ct, &query);
    let mut lookup = Lookup {
        query,
        label: None,
        count: 0,
    };
    if !nct::register_get(&mut handle, nct::COLLECT, &mut lookup) {
        return Err(FlowError::Unavailable);
    }
    if !nct::query_get(&mut handle, &mut ct) {
        return Err(FlowError::Unavailable);
    }
    if lookup.count != 1 {
        return Err(FlowError::Unavailable);
    }
    Ok(lookup.label)
}

#[allow(unsafe_code)]
mod label_shim {
    /// The C boundary kept a plain process-level alarm as the hard stop; no
    /// re-locking handler exists here, so a bounded `alarm(2)` stays cheapest.
    pub(super) fn alarm_after_two_seconds() {
        unsafe {
            libc::alarm(2);
        }
    }
}

#[cfg(test)]
mod tests;

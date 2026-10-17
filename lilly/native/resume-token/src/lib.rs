#![deny(unsafe_code)]
#![doc = "Typed resume-token validation only; this helper never sends disk data."]

use rustix::fs::{Mode as FileMode, OFlags};
use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::OsStrExt;

pub const TOKEN_MAX_BYTES: usize = 8192;
pub const UNPACKED_MAX_BYTES: u64 = 16384;
pub const EXIT_USAGE: u8 = 64;
pub const EXIT_SETUP: u8 = 70;
pub const EXIT_INVALID: u8 = 1;
pub const EXIT_IO: u8 = 74;

/// @cc [owner:ghuntley,label:security] resume-token-bounded-decoding
/// Before calling OpenZFS, tokens MUST have the version-1 envelope, at most
/// 8192 ASCII bytes, even lowercase hexadecimal payload and a declared unpacked
/// size of 1..16384 bytes. The library MUST verify checksum, decompression and
/// nvlist encoding. Failures MUST NOT print the token, arguments or library
/// diagnostics.
/// One lowercase-hex field terminated by '-'. The C field reader limits each
/// to sixteen digits and keeps the value for the caller's bounds policy.
fn field(rest: &[u8]) -> Option<(u64, &[u8])> {
    let dash = rest.iter().position(|b| *b == b'-')?;
    let head = &rest[..dash];
    if head.is_empty() || head.len() > 16 {
        return None;
    }
    if !head
        .iter()
        .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    {
        return None;
    }
    let value = u64::from_str_radix(std::str::from_utf8(head).ok()?, 16).ok()?;
    Some((value, &rest[dash + 1..]))
}

pub fn bounded(token: &str) -> bool {
    if !token.is_ascii() || token.len() > TOKEN_MAX_BYTES || !token.starts_with("1-") {
        return false;
    }
    let Some((_checksum, rest)) = field(&token.as_bytes()[2..]) else {
        return false;
    };
    let Some((unpacked, payload)) = field(rest) else {
        return false;
    };
    if unpacked == 0 || unpacked > UNPACKED_MAX_BYTES {
        return false;
    }
    !payload.is_empty()
        && payload.len().is_multiple_of(2)
        && payload
            .iter()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Envelope {
    pub checksum: u64,
    pub unpacked: u64,
}

/// One decoded nvlist pair.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Pair {
    Str(String, String),
    Uint(String, u64),
    Bool(String),
    Other(String, u32),
}

/// @cc [owner:ghuntley,label:security] resume-token-exact-lineage
/// Validation MUST require one toname/object/offset/bytes/toguid, no duplicate
/// or unknown fields, the exact trusted snapshot name and to GUID, and a zero
/// or absent fromguid: every transfer is one full stream (ADR-0155), so a
/// token naming any parent snapshot fails. Only ordinary large-block, embedded
/// and compressed stream capability booleans are permitted; raw, saved and
/// redacted tokens fail. Successful validation grants neither transfer nor
/// execution authority.
pub fn matches(pairs: &[Pair], name: &str, to: u64) -> bool {
    const KEYS: [&str; 9] = [
        "toname",
        "object",
        "offset",
        "bytes",
        "toguid",
        "fromguid",
        "largeblockok",
        "embedok",
        "compressok",
    ];
    let mut seen: u32 = 0;
    let mut actual_to = 0_u64;
    let mut actual_from = 0_u64;
    for pair in pairs {
        let pair_name = match pair {
            Pair::Str(n, _) | Pair::Uint(n, _) | Pair::Bool(n) | Pair::Other(n, _) => n.as_str(),
        };
        let Some(index) = KEYS.iter().position(|key| *key == pair_name) else {
            return false;
        };
        if seen & (1 << index) != 0 {
            return false;
        }
        seen |= 1 << index;
        match (index, pair) {
            (0, Pair::Str(_, value)) if value.as_str() == name => {}
            (0, _) => return false,
            (1..=5, Pair::Uint(_, value)) => {
                if index == 4 {
                    actual_to = *value;
                }
                if index == 5 {
                    actual_from = *value;
                }
            }
            (1..=5, _) => return false,
            (6..=8, Pair::Bool(_)) => {}
            (6..=8, _) => return false,
            _ => unreachable!(),
        }
    }
    seen & 31 == 31 && actual_to == to && actual_from == 0
}

fn decimal(text: &OsStr) -> Option<u64> {
    let bytes = text.as_bytes();
    if bytes.is_empty() || (bytes[0] == b'0' && bytes.len() > 1) {
        return None;
    }
    if !bytes.iter().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    text.parse::<u64>().ok()
}

/// Validated invocation: snapshot name (with '@'), nonzero to GUID, token text.
#[derive(Debug, Eq, PartialEq)]
pub struct Request {
    pub name: String,
    pub to: u64,
    pub token: String,
}

pub fn parse_cli(arguments: &[OsString]) -> Option<Request> {
    let [name, to, token] = arguments else {
        return None;
    };
    let name = name.to_str()?;
    let token = token
        .to_str()
        .and_then(|token| token.is_ascii().then_some(token))?;
    if name.len() > 255 || !name.contains('@') {
        return None;
    }
    let to = decimal(to)?;
    if to == 0 {
        return None;
    }
    // Token envelopes are selector failures in the C lattice (usage, exit 64),
    // before any library contact.
    if !bounded(token) {
        return None;
    }
    Some(Request {
        name: name.to_string(),
        to,
        token: token.to_string(),
    })
}

pub(crate) fn veil_stderr() -> Result<(), ()> {
    let null = rustix::fs::open(
        "/dev/null",
        OFlags::WRONLY | OFlags::CLOEXEC,
        FileMode::empty(),
    )
    .map_err(|_| ())?;
    let stderr = std::io::stderr();
    let _ = null;
    let _ = stderr;
    // std has no access to fd-based dup2 without unsafe helpers; the pause and
    // silence boundary is the entire surface relocated to the shim.
    libzfs_redirect::silence_stderr(null)
}

#[allow(unsafe_code)]
mod libzfs_redirect {
    use std::os::fd::{AsRawFd, OwnedFd};
    pub(crate) fn silence_stderr(null: OwnedFd) -> Result<(), ()> {
        match unsafe { libc::dup2(null.as_raw_fd(), 2) } {
            2 => Ok(()),
            _ => Err(()),
        }
    }
}

/// The libzfs boundary, paired and typed end to end.
#[allow(unsafe_code)]
mod pairs {
    use super::*;

    #[repr(C)]
    pub struct LibzfsHandle {
        _private: [u8; 0],
    }

    #[repr(C)]
    pub struct Nvlist {
        _private: [u8; 0],
    }

    #[repr(C)]
    pub struct Nvpair {
        _private: [u8; 0],
    }

    #[link(name = "zfs")]
    unsafe extern "C" {
        pub fn libzfs_init() -> *mut LibzfsHandle;
        pub fn libzfs_fini(handle: *mut LibzfsHandle);
        pub fn libzfs_print_on_error(handle: *mut LibzfsHandle, show: libc::c_int);
        pub fn zfs_send_resume_token_to_nvlist(
            handle: *mut LibzfsHandle,
            token: *const libc::c_char,
        ) -> *mut Nvlist;
    }

    #[link(name = "nvpair")]
    unsafe extern "C" {
        pub fn nvlist_free(list: *mut Nvlist);
        pub fn nvlist_next_nvpair(list: *mut Nvlist, previous: *mut Nvpair) -> *mut Nvpair;
        pub fn nvpair_name(pair: *mut Nvpair) -> *const libc::c_char;
        pub fn nvpair_value_string(
            pair: *mut Nvpair,
            value: *mut *const libc::c_char,
        ) -> libc::c_int;
        pub fn nvpair_value_uint64(pair: *mut Nvpair, value: *mut u64) -> libc::c_int;
        pub fn nvpair_type(pair: *mut Nvpair) -> libc::c_int;
    }

    /// libzfs handle with RAII teardown and print-on-error disabled.
    pub struct Library(*mut LibzfsHandle);

    impl Library {
        pub fn init() -> Option<Self> {
            let handle = unsafe { libzfs_init() };
            if handle.is_null() {
                None
            } else {
                unsafe { libzfs_print_on_error(handle, 0) };
                Some(Self(handle))
            }
        }

        pub fn decode_token(&self, token: &str) -> Option<NvlistBorrow<'_>> {
            let text = std::ffi::CString::new(token).ok()?;
            let list = unsafe { zfs_send_resume_token_to_nvlist(self.0, text.as_ptr()) };
            if list.is_null() {
                None
            } else {
                Some(NvlistBorrow {
                    list,
                    _library: self,
                })
            }
        }
    }

    impl Drop for Library {
        fn drop(&mut self) {
            unsafe { libzfs_fini(self.0) }
        }
    }

    /// A borrowed nvlist; disposed before the library on drop.
    pub struct NvlistBorrow<'library> {
        list: *mut Nvlist,
        _library: &'library Library,
    }

    impl NvlistBorrow<'_> {
        pub fn pairs(&self) -> Vec<Pair> {
            let mut out = Vec::new();
            let mut previous: *mut Nvpair = std::ptr::null_mut();
            loop {
                let pair = unsafe { nvlist_next_nvpair(self.list, previous) };
                if pair.is_null() {
                    break;
                }
                let name_c = unsafe { nvpair_name(pair) };
                if name_c.is_null() {
                    break;
                }
                let name = unsafe { std::ffi::CStr::from_ptr(name_c) }
                    .to_string_lossy()
                    .into_owned();
                let entry = match unsafe { nvpair_type(pair) } {
                    1 => Pair::Bool(name),
                    9 => {
                        let mut text: *const libc::c_char = std::ptr::null();
                        match unsafe { nvpair_value_string(pair, &mut text) } {
                            0 if !text.is_null() => Pair::Str(
                                name,
                                unsafe { std::ffi::CStr::from_ptr(text) }
                                    .to_string_lossy()
                                    .into_owned(),
                            ),
                            _ => Pair::Other(name, 9),
                        }
                    }
                    8 => {
                        let mut value = 0_u64;
                        match unsafe { nvpair_value_uint64(pair, &mut value) } {
                            0 => Pair::Uint(name, value),
                            _ => Pair::Other(name, 8),
                        }
                    }
                    kind => Pair::Other(name, u32::try_from(kind).unwrap_or(u32::MAX)),
                };
                out.push(entry);
                previous = pair;
            }
            out
        }
    }

    impl Drop for NvlistBorrow<'_> {
        fn drop(&mut self) {
            unsafe { nvlist_free(self.list) }
        }
    }
}

/// The production evaluator: bounds first, library second, questions never echo.
pub fn matches_current(request: &Request) -> Result<bool, u8> {
    debug_assert!(bounded(&request.token), "selectors keep bounded tokens");
    veil_stderr().map_err(|_| EXIT_SETUP)?;
    let library = pairs::Library::init().ok_or(EXIT_INVALID)?;
    let Some(list) = library.decode_token(&request.token) else {
        return Ok(false);
    };
    Ok(matches(&list.pairs(), &request.name, request.to))
}

pub fn run(request: &Request) -> u8 {
    match matches_current(request) {
        Ok(true) => {
            let stdout = std::io::stdout();
            match rustix::io::write(stdout, b"ok\n") {
                Ok(3) => 0,
                _ => EXIT_IO,
            }
        }
        Ok(false) => EXIT_INVALID,
        Err(code) => code,
    }
}

#[cfg(test)]
mod tests;

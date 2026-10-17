#![forbid(unsafe_code)]

use rustix::fs::{
    copy_file_range, flock, fstatvfs, ioctl_ficlone, open, seek, FlockOperation, Mode as FileMode,
    OFlags, SeekFrom, StatVfsMountFlags,
};
use rustix::io::Errno;
use std::fs::{File, Metadata};
use std::io;
use std::os::fd::OwnedFd;
use std::os::unix::fs::{FileExt, MetadataExt};
use std::path::Path;

pub const MAX_BYTES: u64 = 137_438_953_472;
/// Largest guest disk (OverallsProtocol.VmShape.maximum_disk_bytes).
pub const SNAPSHOT_MAX_BYTES: u64 = 536_870_912_000;

/// @cc [owner:ghuntley,label:security;isolation] image-helper-snapshot-source
/// Image sources MUST be root-owned and unwritable. Snapshot sources (same-pool
/// clone copies, ADR-0145) MUST be single-link regular files owned by the exact
/// expected guest uid on a filesystem that reports itself read-only, bounded by
/// the maximum guest disk size. No other source shape is accepted.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SourcePolicy {
    Image,
    Snapshot { uid: u32 },
}

impl SourcePolicy {
    fn max_bytes(self) -> u64 {
        match self {
            Self::Image => MAX_BYTES,
            Self::Snapshot { .. } => SNAPSHOT_MAX_BYTES,
        }
    }
}

fn read_only_filesystem(file: &File) -> Result<bool, Errno> {
    Ok(fstatvfs(file)?.f_flag.contains(StatVfsMountFlags::RDONLY))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Mode {
    Auto,
    Copy,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Method {
    Reflink,
    Offload,
    Copy,
}

impl Method {
    pub fn wire(self) -> &'static str {
        match self {
            Self::Reflink => "reflink",
            Self::Offload => "offload",
            Self::Copy => "copy",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    Arguments,
    Source,
    Destination,
    Clone,
    Copy,
    Changed,
    Sync,
    Lease,
}

/// @cc [owner:ghuntley,label:security] native-artifact-nanosecond-identity
/// Identity MUST include file descriptor device, inode, size, mode, owner, links
/// and nanosecond modification/change timestamps. Access time MUST be excluded.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Identity(pub [u64; 11]);

impl Identity {
    fn read(metadata: &Metadata) -> Result<Self, Error> {
        let nonnegative = |value: i64| u64::try_from(value).map_err(|_| Error::Source);
        Ok(Self([
            metadata.dev(),
            metadata.ino(),
            metadata.size(),
            u64::from(metadata.mode()),
            u64::from(metadata.uid()),
            u64::from(metadata.gid()),
            metadata.nlink(),
            nonnegative(metadata.mtime())?,
            nonnegative(metadata.mtime_nsec())?,
            nonnegative(metadata.ctime())?,
            nonnegative(metadata.ctime_nsec())?,
        ]))
    }
}

fn source(path: &Path) -> Result<(File, Metadata), Error> {
    checked_source(path, SourcePolicy::Image, read_only_filesystem)
}

fn checked_source(
    path: &Path,
    policy: SourcePolicy,
    read_only: impl FnOnce(&File) -> Result<bool, Errno>,
) -> Result<(File, Metadata), Error> {
    let descriptor = open(
        path,
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::NONBLOCK,
        FileMode::empty(),
    )
    .map_err(|_| Error::Source)?;
    let file = File::from(descriptor);
    let metadata = file.metadata().map_err(|_| Error::Source)?;
    let acceptable = match policy {
        SourcePolicy::Image => {
            metadata.uid() == rustix::process::geteuid().as_raw() && metadata.mode() & 0o222 == 0
        }
        SourcePolicy::Snapshot { uid } => {
            metadata.uid() == uid
                && metadata.nlink() == 1
                && read_only(&file).map_err(|_| Error::Source)?
        }
    };
    if !metadata.is_file() || !acceptable {
        return Err(Error::Source);
    }
    Ok((file, metadata))
}

pub fn identity(path: &Path) -> Result<Identity, Error> {
    let (_file, metadata) = source(path)?;
    if metadata.nlink() != 1 {
        return Err(Error::Source);
    }
    Identity::read(&metadata)
}

pub fn parse_snapshot_size(value: &str) -> Result<u64, Error> {
    parse_bounded(value, SNAPSHOT_MAX_BYTES)
}

pub fn parse_size(value: &str) -> Result<u64, Error> {
    parse_bounded(value, MAX_BYTES)
}

fn parse_bounded(value: &str, max: u64) -> Result<u64, Error> {
    if value.is_empty() || value.starts_with('0') || !value.bytes().all(|b| b.is_ascii_digit()) {
        return Err(Error::Arguments);
    }
    value
        .parse::<u64>()
        .ok()
        .filter(|size| (1..=max).contains(size))
        .ok_or(Error::Arguments)
}

/// @cc [owner:ghuntley,label:security;recovery] image-copy-fallback-allowlist
/// Only EXDEV, ENOTTY and EOPNOTSUPP permit the next copy strategy (ENOSYS
/// additionally for kernel copy offload). I/O, permissions, space/quota
/// exhaustion, malformed requests and unknown errors MUST fail.
pub fn unsupported(error: Errno) -> bool {
    matches!(error, Errno::XDEV | Errno::NOTTY | Errno::OPNOTSUPP)
}

fn offload_unsupported(error: Errno) -> bool {
    unsupported(error) || error == Errno::NOSYS
}

/// @cc [owner:ghuntley,label:durability;isolation] independent-image-materialization
/// Materialization MUST exclusively create an independent destination and never
/// follow a leaf symlink or overwrite an existing file. Verify source shape,
/// owner and bounded size before creation; recheck its full identity and sync
/// the destination before success. Callers hold native ownership, validate
/// ancestors and publish by rename. Failed temporary files remain caller-owned.
pub fn materialize(
    mode: Mode,
    source_path: &Path,
    destination: &Path,
    size: u64,
) -> Result<Method, Error> {
    materialize_with(
        mode,
        source_path,
        destination,
        size,
        SourcePolicy::Image,
        read_only_filesystem,
        |target, source| ioctl_ficlone(target, source),
        |target, source, offset, length| {
            let (mut input, mut output) = (offset, offset);
            copy_file_range(source, Some(&mut input), target, Some(&mut output), length)
        },
    )
}

/// @cc [owner:ghuntley,label:recovery;concurrency] copy-child-retains-source-lease
/// A leased copy MUST acquire the existing private, single-link native lease
/// inode without following symlinks or creating files. Its independent shared
/// descriptor MUST remain held through source verification and destination sync,
/// even if the caller's template lease closes. The caller independently delegates
/// the child to its placement lock owner to retain destination fencing.
pub fn materialize_leased(
    mode: Mode,
    source: &Path,
    destination: &Path,
    size: u64,
    lease: &Path,
) -> Result<Method, Error> {
    with_source_lease(lease, || materialize(mode, source, destination, size))
}

fn with_source_lease(
    lease: &Path,
    copy: impl FnOnce() -> Result<Method, Error>,
) -> Result<Method, Error> {
    let _lease = source_lease(lease)?;
    copy()
}

fn source_lease(path: &Path) -> Result<OwnedFd, Error> {
    let descriptor = open(
        path,
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::NONBLOCK,
        FileMode::empty(),
    )
    .map_err(|_| Error::Lease)?;
    let file = File::from(descriptor);
    let metadata = file.metadata().map_err(|_| Error::Lease)?;
    if !metadata.is_file()
        || metadata.uid() != rustix::process::geteuid().as_raw()
        || metadata.mode() & 0o777 != 0o600
        || metadata.nlink() != 1
    {
        return Err(Error::Lease);
    }
    flock(&file, FlockOperation::NonBlockingLockShared).map_err(|_| Error::Lease)?;
    Ok(file.into())
}

/// Materialize a same-pool clone disk from a read-only snapshot mount (ADR-0145):
/// the same exclusive, verified and synced destination rules as images, with the
/// snapshot source policy for the exact expected guest uid.
pub fn materialize_snapshot(
    source_path: &Path,
    destination: &Path,
    size: u64,
    uid: u32,
) -> Result<Method, Error> {
    materialize_with(
        Mode::Auto,
        source_path,
        destination,
        size,
        SourcePolicy::Snapshot { uid },
        read_only_filesystem,
        |target, source| ioctl_ficlone(target, source),
        |target, source, offset, length| {
            let (mut input, mut output) = (offset, offset);
            copy_file_range(source, Some(&mut input), target, Some(&mut output), length)
        },
    )
}

#[allow(clippy::too_many_arguments)]
fn materialize_with(
    mode: Mode,
    source_path: &Path,
    destination: &Path,
    size: u64,
    policy: SourcePolicy,
    read_only: impl FnOnce(&File) -> Result<bool, Errno>,
    clone: impl FnOnce(&File, &File) -> Result<(), Errno>,
    offload: impl FnMut(&File, &File, u64, usize) -> Result<usize, Errno>,
) -> Result<Method, Error> {
    if !(1..=policy.max_bytes()).contains(&size) {
        return Err(Error::Arguments);
    }
    let (source, metadata) = checked_source(source_path, policy, read_only)?;
    if metadata.len() != size {
        return Err(Error::Source);
    }
    let before = Identity::read(&metadata)?;
    let target = File::from(
        open(
            destination,
            OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::CLOEXEC | OFlags::NOFOLLOW,
            FileMode::from_raw_mode(0o600),
        )
        .map_err(|_| Error::Destination)?,
    );
    let method = match mode {
        Mode::Copy => Method::Copy,
        Mode::Auto => match clone(&target, &source) {
            Ok(()) => Method::Reflink,
            Err(error) if unsupported(error) => offload_range(&source, &target, size, offload)?,
            Err(_) => return Err(Error::Clone),
        },
    };
    if method == Method::Copy {
        sparse_copy(&source, &target, size).map_err(|_| Error::Copy)?;
    }
    let after = source.metadata().map_err(|_| Error::Changed)?;
    let target_metadata = target.metadata().map_err(|_| Error::Changed)?;
    if Identity::read(&after)? != before
        || !target_metadata.is_file()
        || target_metadata.len() != size
        || target_metadata.nlink() != 1
    {
        return Err(Error::Changed);
    }
    target.sync_all().map_err(|_| Error::Sync)?;
    Ok(method)
}

/// @cc [owner:ghuntley,label:performance;durability] image-copy-source-extents
/// Copies MUST transfer only the source's data extents as reported by
/// `lseek(SEEK_DATA)`/`lseek(SEEK_HOLE)` and leave every hole a hole: the
/// destination is sized to the source length after the extents are written.
/// A filesystem that cannot report holes (`EINVAL`) is one data extent from 0
/// to the size; extents MUST be ascending, non-empty and inside the size, and
/// any other seek failure fails the copy. A 64 GiB sparse Windows disk with
/// 22 GB of data then moves 22 GB, not 64 GiB (ADR-0173).
fn data_extents(source: &File, size: u64) -> Result<Vec<(u64, u64)>, Error> {
    let mut extents = Vec::new();
    let mut offset = 0_u64;
    while offset < size {
        let start = match seek(source, SeekFrom::Data(offset)) {
            Ok(start) => start,
            Err(Errno::NXIO) => break,
            Err(Errno::INVAL) if offset == 0 => return Ok(vec![(0, size)]),
            Err(_) => return Err(Error::Copy),
        };
        if start >= size {
            break;
        }
        if start < offset {
            return Err(Error::Copy);
        }
        let end = match seek(source, SeekFrom::Hole(start)) {
            Ok(end) => end.min(size),
            Err(_) => return Err(Error::Copy),
        };
        if end <= start {
            return Err(Error::Copy);
        }
        extents.push((start, end));
        offset = end;
    }
    Ok(extents)
}

/// @cc [owner:ghuntley,label:performance;durability] image-copy-kernel-offload
/// When whole-file cloning is unsupported (e.g. FICLONE across mounts), kernel
/// copy offload MUST be attempted before userspace copying so filesystems such
/// as ZFS can share blocks across datasets. Only an unsupported refusal before
/// any byte is transferred may fall back; a partial transfer, short read or
/// repeated interruption or any other error MUST fail without publishing the
/// destination.
fn offload_range(
    source: &File,
    target: &File,
    size: u64,
    mut offload: impl FnMut(&File, &File, u64, usize) -> Result<usize, Errno>,
) -> Result<Method, Error> {
    const WINDOW: u64 = 1 << 30;
    const INTERRUPTS: u32 = 16;
    let mut transferred = 0_u64;
    for (start, end) in data_extents(source, size)? {
        let (mut offset, mut interrupts) = (start, 0_u32);
        while offset < end {
            let length = usize::try_from((end - offset).min(WINDOW)).map_err(|_| Error::Copy)?;
            match offload(target, source, offset, length) {
                Ok(0) => return Err(Error::Copy),
                Ok(count) if count as u64 <= end - offset => {
                    offset += count as u64;
                    transferred += count as u64;
                    interrupts = 0;
                }
                Ok(_) => return Err(Error::Copy),
                Err(Errno::INTR) if interrupts < INTERRUPTS => interrupts += 1,
                Err(error) if transferred == 0 && offload_unsupported(error) => {
                    return Ok(Method::Copy)
                }
                Err(_) => return Err(Error::Copy),
            }
        }
    }
    target.set_len(size).map_err(|_| Error::Copy)?;
    Ok(Method::Offload)
}

fn sparse_copy(source: &File, target: &File, size: u64) -> io::Result<()> {
    let mut buffer = vec![0_u8; 1024 * 1024];
    let extents = data_extents(source, size).map_err(|_| io::Error::other("source extents"))?;
    for (start, end) in extents {
        let mut offset = start;
        while offset < end {
            let count = usize::try_from((end - offset).min(buffer.len() as u64))
                .map_err(|_| io::ErrorKind::InvalidInput)?;
            let count = match source.read_at(&mut buffer[..count], offset) {
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                other => other?,
            };
            if count == 0 {
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
            if buffer[..count].iter().any(|byte| *byte != 0) {
                target.write_all_at(&buffer[..count], offset)?;
            }
            offset += count as u64;
        }
    }
    target.set_len(size)
}

#[cfg(test)]
mod tests;

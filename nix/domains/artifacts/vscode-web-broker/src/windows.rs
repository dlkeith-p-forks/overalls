//! Staged Windows worker custody/launcher. No listener or guest capability is enabled.
//!
//! The caller must reconcile the account using the current boot-bound roster
//! authorizer before resolving its SID and constructing an admitted identity.
//! Package paths come from trusted, immutable deployment configuration. The
//! caller must single-flight startup and retain a SYSTEM-owned launch receipt.

use crate::Refusal;
use crate::windows_model::{
    AccountSid, LocalPath, PipePeer, ProcessIdentity, WorkerIdentity, command_line, verify_peer,
};
use crate::windows_pipe::Pipe;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::mem::{size_of, zeroed};
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicU64, Ordering};
use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_ALREADY_EXISTS, ERROR_FILE_NOT_FOUND, ERROR_INVALID_PARAMETER,
    ERROR_NOT_ALL_ASSIGNED, FILETIME, GetLastError, HANDLE, LUID, LocalFree, SetLastError,
    WAIT_OBJECT_0,
};
use windows_sys::Win32::NetworkManagement::NetManagement::{
    NetApiBufferFree, NetUserGetInfo, UF_ACCOUNTDISABLE, USER_INFO_4,
};
use windows_sys::Win32::Security::Authentication::Identity::{
    LSA_STRING, LSA_UNICODE_STRING, LsaDeregisterLogonProcess, LsaFreeReturnBuffer, LsaLogonUser,
    LsaLookupAuthenticationPackage, LsaRegisterLogonProcess, MSV1_0_S4U_LOGON, MsV1_0S4ULogon,
    SECURITY_LOGON_TYPE,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo, SE_KERNEL_OBJECT,
};
use windows_sys::Win32::Security::{
    ACCESS_ALLOWED_ACE, AdjustTokenPrivileges, AllocateLocallyUniqueId, DACL_SECURITY_INFORMATION,
    DuplicateTokenEx, EqualSid, GetAce, GetLengthSid, GetSecurityDescriptorControl,
    GetTokenInformation, IsValidSid, LUID_AND_ATTRIBUTES, LookupPrivilegeValueW,
    OWNER_SECURITY_INFORMATION, QUOTA_LIMITS, SE_ASSIGNPRIMARYTOKEN_NAME, SE_DACL_PROTECTED,
    SE_INCREASE_QUOTA_NAME, SE_PRIVILEGE_ENABLED, SE_TCB_NAME, SECURITY_ATTRIBUTES,
    SecurityImpersonation, TOKEN_ADJUST_PRIVILEGES, TOKEN_ALL_ACCESS, TOKEN_PRIVILEGES,
    TOKEN_QUERY, TOKEN_SOURCE, TOKEN_USER, TokenPrimary, TokenUser,
};
use windows_sys::Win32::Storage::FileSystem::{
    BY_HANDLE_FILE_INFORMATION, CreateDirectoryW, FILE_ATTRIBUTE_DIRECTORY,
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_FLAG_OVERLAPPED, FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE, FILE_SHARE_READ,
    FILE_SHARE_WRITE, GetFileInformationByHandle, MOVEFILE_REPLACE_EXISTING,
    MOVEFILE_WRITE_THROUGH, MoveFileExW, READ_CONTROL, SECURITY_IDENTIFICATION,
    SECURITY_SQOS_PRESENT,
};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, IsProcessInJob, JOB_OBJECT_LIMIT_ACTIVE_PROCESS,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation, OpenJobObjectW,
    SetInformationJobObject, TerminateJobObject,
};
use windows_sys::Win32::System::Pipes::{GetNamedPipeServerProcessId, WaitNamedPipeW};
use windows_sys::Win32::System::Threading::{
    CREATE_NO_WINDOW, CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, CreateProcessAsUserW,
    GetCurrentProcess, GetProcessId, GetProcessTimes, OpenProcess, OpenProcessToken,
    PROCESS_INFORMATION, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE,
    QueryFullProcessImageNameW, ResumeThread, STARTUPINFOW, TerminateProcess, WaitForSingleObject,
};
use windows_sys::Win32::UI::Shell::GetUserProfileDirectoryW;

const JOB_QUERY: u32 = 4;
const JOB_TERMINATE: u32 = 8;
const JOB_ALL_ACCESS: u32 = 0x001f003f;

fn system_sid() -> [u32; 3] {
    [0x00000101, 0x05000000, 18]
}
fn administrators_sid() -> [u32; 4] {
    [0x00000201, 0x05000000, 32, 544]
}

/// Refuse execution unless this broker is running as LocalSystem.
pub fn require_system() -> Result<(), Refusal> {
    let mut token = null_mut();
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(Refusal::Custody);
    }
    let token = owned(token, Refusal::Custody)?;
    let mut buffer = [0_usize; 32];
    let mut length = 0;
    if unsafe {
        GetTokenInformation(
            raw(&token),
            TokenUser,
            buffer.as_mut_ptr().cast(),
            size_of_val(&buffer) as u32,
            &mut length,
        )
    } == 0
        || length as usize > size_of_val(&buffer)
        || (length as usize) < size_of::<TOKEN_USER>()
    {
        return Err(Refusal::Custody);
    }
    let sid = unsafe { (*buffer.as_ptr().cast::<TOKEN_USER>()).User.Sid };
    let system = system_sid();
    if unsafe { EqualSid(sid, system.as_ptr().cast_mut().cast()) } == 0 {
        return Err(Refusal::Custody);
    }
    Ok(())
}

fn path_handle(path: &str) -> Result<File, Refusal> {
    OpenOptions::new()
        .access_mode(READ_CONTROL | FILE_READ_ATTRIBUTES)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
        .map_err(|_| Refusal::Custody)
}

fn attributes(file: &File) -> Result<u32, Refusal> {
    let mut information: BY_HANDLE_FILE_INFORMATION = unsafe { zeroed() };
    if unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut information) } == 0
        || information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
    {
        return Err(Refusal::Custody);
    }
    Ok(information.dwFileAttributes)
}

fn file_acl(file: &File, system_only: bool, ancestor: bool) -> Result<(), Refusal> {
    let mut owner = null_mut();
    let mut dacl = null_mut();
    let mut descriptor = null_mut();
    if unsafe {
        GetSecurityInfo(
            file.as_raw_handle(),
            windows_sys::Win32::Security::Authorization::SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            null_mut(),
            &mut dacl,
            null_mut(),
            &mut descriptor,
        )
    } != 0
    {
        return Err(Refusal::Custody);
    }
    let result = (|| {
        let system = system_sid();
        let administrators = administrators_sid();
        let is_system = |sid| unsafe { EqualSid(sid, system.as_ptr().cast_mut().cast()) } != 0;
        let is_admin =
            |sid| unsafe { EqualSid(sid, administrators.as_ptr().cast_mut().cast()) } != 0;
        if owner.is_null()
            || dacl.is_null()
            || (system_only && !is_system(owner))
            || (!system_only && !ancestor && !is_system(owner) && !is_admin(owner))
        {
            return Err(Refusal::Custody);
        }
        let count = unsafe { (*dacl).AceCount };
        if count == 0 || count > 128 {
            return Err(Refusal::Custody);
        }
        for index in 0..u32::from(count) {
            let mut ace = null_mut();
            if unsafe { GetAce(dacl, index, &mut ace) } == 0 || ace.is_null() {
                return Err(Refusal::Custody);
            }
            let allowed = unsafe { &*ace.cast::<ACCESS_ALLOWED_ACE>() };
            if allowed.Header.AceType == 1 {
                continue;
            } // Denials cannot grant write authority.
            if allowed.Header.AceType != 0
                || (allowed.Header.AceSize as usize) < size_of::<ACCESS_ALLOWED_ACE>()
            {
                return Err(Refusal::Custody);
            }
            if allowed.Header.AceFlags & 8 != 0 {
                continue;
            } // INHERIT_ONLY does not apply here.
            let sid = (&raw const allowed.SidStart).cast_mut().cast();
            if is_system(sid) {
                continue;
            }
            if system_only {
                return Err(Refusal::Custody);
            }
            if is_admin(sid) {
                continue;
            }
            // A parent may allow creation of unrelated children. It MUST NOT
            // allow replacing/deleting this already-owned child or its ACL.
            let write_mask = 0x500d0040 | if ancestor { 0 } else { 0x00000116 };
            if allowed.Mask & write_mask != 0 {
                return Err(Refusal::Custody);
            }
        }
        Ok(())
    })();
    unsafe {
        LocalFree(descriptor);
    }
    result
}

fn ancestors(path: &LocalPath) -> Result<(), Refusal> {
    let mut parent = std::path::Path::new(path.as_str()).parent();
    while let Some(directory) = parent {
        let text = directory.to_str().ok_or(Refusal::Custody)?;
        let handle = path_handle(text)?;
        if attributes(&handle)? & FILE_ATTRIBUTE_DIRECTORY == 0 {
            return Err(Refusal::Custody);
        }
        file_acl(&handle, false, true)?;
        parent = directory.parent();
    }
    Ok(())
}

/// @cc [owner:ghuntley,label:security] windows-editor-package-path-custody
/// Configured executable/configuration/certificate paths MUST be real regular
/// files with SYSTEM or Administrators ownership and write authority only for
/// those principals. Every ancestor MUST refuse reparse traversal and foreign
/// replacement/delete/ACL authority. A caller path or existence alone MUST NOT
/// establish immutable package custody.
pub fn package_file(path: &LocalPath) -> Result<(), Refusal> {
    ancestors(path)?;
    let file = path_handle(path.as_str())?;
    if attributes(&file)? & FILE_ATTRIBUTE_DIRECTORY != 0 {
        return Err(Refusal::Custody);
    }
    file_acl(&file, false, false)
}

fn checked_private_directory(path: &LocalPath) -> Result<(), Refusal> {
    ancestors(path)?;
    let directory = path_handle(path.as_str())?;
    if attributes(&directory)? & FILE_ATTRIBUTE_DIRECTORY == 0 {
        return Err(Refusal::Custody);
    }
    file_acl(&directory, true, false)
}

/// Create only the final directory under trusted ancestors, with SYSTEM-only ACL.
pub fn private_directory(path: &LocalPath) -> Result<(), Refusal> {
    require_system()?;
    ancestors(path)?;
    if std::path::Path::new(path.as_str()).exists() {
        return checked_private_directory(path);
    }
    let sddl = wide("O:SYG:SYD:P(A;OICI;FA;;;SY)");
    let mut descriptor = null_mut();
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descriptor,
            null_mut(),
        )
    } == 0
    {
        return Err(Refusal::Custody);
    }
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor,
        bInheritHandle: 0,
    };
    let name = wide(path.as_str());
    let created = unsafe { CreateDirectoryW(name.as_ptr(), &attributes) };
    let existed = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
    unsafe {
        LocalFree(descriptor);
    }
    if created == 0 && !existed {
        return Err(Refusal::Custody);
    }
    checked_private_directory(path)
}

fn private_parent(path: &LocalPath) -> Result<(), Refusal> {
    let parent = std::path::Path::new(path.as_str())
        .parent()
        .and_then(std::path::Path::to_str)
        .ok_or(Refusal::Custody)?;
    checked_private_directory(&LocalPath::parse(parent).map_err(|_| Refusal::Custody)?)
}

/// Read a bounded ordinary receipt only after SYSTEM-only parent/file custody.
pub fn read_private(path: &LocalPath, maximum: usize) -> Result<Vec<u8>, Refusal> {
    require_system()?;
    private_parent(path)?;
    if maximum == 0 || maximum > 65536 {
        return Err(Refusal::Custody);
    }
    let file = OpenOptions::new()
        .read(true)
        .access_mode(0x80000000 | READ_CONTROL)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path.as_str())
        .map_err(|_| Refusal::Custody)?;
    if attributes(&file)? & FILE_ATTRIBUTE_DIRECTORY != 0 {
        return Err(Refusal::Custody);
    }
    file_acl(&file, true, false)?;
    let mut bytes = Vec::new();
    file.take(maximum as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Refusal::Custody)?;
    if bytes.is_empty() || bytes.len() > maximum {
        return Err(Refusal::Custody);
    }
    Ok(bytes)
}

/// Read an optional receipt. Absence is the only non-error state; ACL,
/// reparse, malformed, and other I/O failures remain custody refusals.
pub fn read_private_optional(path: &LocalPath, maximum: usize) -> Result<Option<Vec<u8>>, Refusal> {
    require_system()?;
    private_parent(path)?;
    if maximum == 0 || maximum > 65536 {
        return Err(Refusal::Custody);
    }
    let file = match OpenOptions::new()
        .read(true)
        .access_mode(0x80000000 | READ_CONTROL)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path.as_str())
    {
        Ok(file) => file,
        Err(error) if error.raw_os_error() == Some(ERROR_FILE_NOT_FOUND as i32) => return Ok(None),
        Err(_) => return Err(Refusal::Custody),
    };
    if attributes(&file)? & FILE_ATTRIBUTE_DIRECTORY != 0 {
        return Err(Refusal::Custody);
    }
    file_acl(&file, true, false)?;
    let mut bytes = Vec::new();
    file.take(maximum as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Refusal::Custody)?;
    if bytes.is_empty() || bytes.len() > maximum {
        return Err(Refusal::Custody);
    }
    Ok(Some(bytes))
}

/// Publish a complete bounded receipt by rename under its SYSTEM-only parent.
pub fn write_private(path: &LocalPath, bytes: &[u8]) -> Result<(), Refusal> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    require_system()?;
    private_parent(path)?;
    if bytes.is_empty() || bytes.len() > 65536 {
        return Err(Refusal::Custody);
    }
    let temporary = format!(
        "{}.{}.{}.tmp",
        path.as_str(),
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    );
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .access_mode(0x40000000 | READ_CONTROL)
            .share_mode(0)
            .open(&temporary)
            .map_err(|_| Refusal::Custody)?;
        attributes(&file)?;
        file_acl(&file, true, false)?;
        file.write_all(bytes)
            .and_then(|()| file.sync_all())
            .map_err(|_| Refusal::Custody)?;
        drop(file);
        let source = wide(&temporary);
        let destination = wide(path.as_str());
        if unsafe {
            MoveFileExW(
                source.as_ptr(),
                destination.as_ptr(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        } == 0
        {
            return Err(Refusal::Custody);
        }
        let published = read_private(path, bytes.len())?;
        (published == bytes).then_some(()).ok_or(Refusal::Custody)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain([0]).collect()
}

fn owned(handle: HANDLE, refusal: Refusal) -> Result<OwnedHandle, Refusal> {
    if handle.is_null() || handle == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
        return Err(refusal);
    }
    // SAFETY: the caller transferred a newly acquired, uniquely owned handle.
    Ok(unsafe { OwnedHandle::from_raw_handle(handle) })
}

fn raw(handle: &OwnedHandle) -> HANDLE {
    handle.as_raw_handle()
}

fn copy_sid(pointer: windows_sys::Win32::Security::PSID) -> Result<AccountSid, Refusal> {
    // SAFETY: callers supply a SID pointer within a live successful Win32 result.
    if pointer.is_null() || unsafe { IsValidSid(pointer) } == 0 {
        return Err(Refusal::Account);
    }
    let length = unsafe { GetLengthSid(pointer) } as usize;
    if length != 28 {
        return Err(Refusal::Account);
    }
    AccountSid::parse(unsafe { std::slice::from_raw_parts(pointer.cast::<u8>(), length) })
}

/// @cc [owner:ghuntley,label:security] windows-editor-resolve-current-local-sid
/// Resolution MUST use the enabled local SAM account for the exact canonical
/// u<uid> name after fresh roster reconciliation. It MUST NOT resolve a domain
/// fallback or infer the SID from a name, UID or profile-directory convention.
pub fn resolve_account(uid: u32, username: &str) -> Result<AccountSid, Refusal> {
    if !(200_000..=999_999).contains(&uid) || username != format!("u{uid}") {
        return Err(Refusal::Account);
    }
    let name = wide(username);
    let mut buffer = null_mut();
    // SAFETY: level four returns one local SAM record owned by NetApi.
    if unsafe { NetUserGetInfo(null(), name.as_ptr(), 4, &mut buffer) } != 0 || buffer.is_null() {
        return Err(Refusal::Account);
    }
    let result = (|| {
        let record = unsafe { &*buffer.cast::<USER_INFO_4>() };
        if record.usri4_flags & UF_ACCOUNTDISABLE != 0 {
            return Err(Refusal::Account);
        }
        copy_sid(record.usri4_user_sid)
    })();
    unsafe {
        NetApiBufferFree(buffer.cast());
    }
    result
}

fn token_sid(token: HANDLE) -> Result<AccountSid, Refusal> {
    // A TOKEN_USER is pointer aligned; the remaining buffer holds its SID.
    let mut buffer = [0_usize; 32];
    let mut length = 0;
    if unsafe {
        GetTokenInformation(
            token,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            size_of_val(&buffer) as u32,
            &mut length,
        )
    } == 0
        || length as usize > size_of_val(&buffer)
        || (length as usize) < size_of::<TOKEN_USER>()
    {
        return Err(Refusal::Custody);
    }
    let record = unsafe { &*buffer.as_ptr().cast::<TOKEN_USER>() };
    copy_sid(record.User.Sid).map_err(|_| Refusal::Custody)
}

fn privilege(name: *const u16) -> Result<(), Refusal> {
    let mut token = null_mut();
    if unsafe {
        OpenProcessToken(
            GetCurrentProcess(),
            TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
            &mut token,
        )
    } == 0
    {
        return Err(Refusal::Startup);
    }
    let token = owned(token, Refusal::Startup)?;
    let mut luid: LUID = unsafe { zeroed() };
    if unsafe { LookupPrivilegeValueW(null(), name, &mut luid) } == 0 {
        return Err(Refusal::Startup);
    }
    let privileges = TOKEN_PRIVILEGES {
        PrivilegeCount: 1,
        Privileges: [LUID_AND_ATTRIBUTES {
            Luid: luid,
            Attributes: SE_PRIVILEGE_ENABLED,
        }],
    };
    unsafe {
        SetLastError(0);
    }
    if unsafe { AdjustTokenPrivileges(raw(&token), 0, &privileges, 0, null_mut(), null_mut()) } == 0
        || unsafe { GetLastError() } == ERROR_NOT_ALL_ASSIGNED
    {
        return Err(Refusal::Startup);
    }
    Ok(())
}

/// Passwordless local-account logon, with explicit primary-token duplication.
fn account_token(identity: &WorkerIdentity) -> Result<OwnedHandle, Refusal> {
    if resolve_account(identity_uid(identity)?, identity.username())? != *identity.sid() {
        return Err(Refusal::Account);
    }
    let mut process_name = *b"overalls-editor";
    let process = LSA_STRING {
        Length: process_name.len() as u16,
        MaximumLength: process_name.len() as u16,
        Buffer: process_name.as_mut_ptr(),
    };
    let mut lsa = null_mut();
    let mut mode = 0;
    if unsafe { LsaRegisterLogonProcess(&process, &mut lsa, &mut mode) } != 0 {
        return Err(Refusal::Account);
    }
    let result = (|| {
        let mut package_name = *b"MICROSOFT_AUTHENTICATION_PACKAGE_V1_0";
        let package = LSA_STRING {
            Length: package_name.len() as u16,
            MaximumLength: package_name.len() as u16,
            Buffer: package_name.as_mut_ptr(),
        };
        let mut package_id = 0;
        if unsafe { LsaLookupAuthenticationPackage(lsa, &package, &mut package_id) } != 0 {
            return Err(Refusal::Account);
        }
        let user: Vec<u16> = identity.username().encode_utf16().collect();
        let header = size_of::<MSV1_0_S4U_LOGON>();
        let total = header + (user.len() + 1) * 2;
        let mut storage = vec![0_u64; total.div_ceil(8)];
        let base = storage.as_mut_ptr().cast::<u8>();
        // SAFETY: aligned request plus both bounded UTF-16 strings are in storage.
        unsafe {
            let user_at = base.add(header).cast::<u16>();
            std::ptr::copy_nonoverlapping(user.as_ptr(), user_at, user.len());
            let domain_at = user_at.add(user.len());
            *domain_at = b'.' as u16;
            *base.cast::<MSV1_0_S4U_LOGON>() = MSV1_0_S4U_LOGON {
                MessageType: MsV1_0S4ULogon,
                Flags: 0,
                UserPrincipalName: LSA_UNICODE_STRING {
                    Length: (user.len() * 2) as u16,
                    MaximumLength: (user.len() * 2) as u16,
                    Buffer: user_at,
                },
                DomainName: LSA_UNICODE_STRING {
                    Length: 2,
                    MaximumLength: 2,
                    Buffer: domain_at,
                },
            };
        }
        let mut source: TOKEN_SOURCE = unsafe { zeroed() };
        for (slot, byte) in source.SourceName.iter_mut().zip(b"overalls") {
            *slot = *byte as i8;
        }
        if unsafe { AllocateLocallyUniqueId(&mut source.SourceIdentifier) } == 0 {
            return Err(Refusal::Account);
        }
        let mut profile = null_mut();
        let mut profile_length = 0;
        let mut logon: LUID = unsafe { zeroed() };
        let mut token = null_mut();
        let mut quotas: QUOTA_LIMITS = unsafe { zeroed() };
        let mut substatus = 0;
        let status = unsafe {
            LsaLogonUser(
                lsa,
                &process,
                SECURITY_LOGON_TYPE::Network,
                package_id,
                storage.as_ptr().cast(),
                total as u32,
                null(),
                &source,
                &mut profile,
                &mut profile_length,
                &mut logon,
                &mut token,
                &mut quotas,
                &mut substatus,
            )
        };
        if !profile.is_null() {
            unsafe {
                LsaFreeReturnBuffer(profile);
            }
        }
        if status != 0 {
            if !token.is_null() {
                unsafe {
                    CloseHandle(token);
                }
            }
            return Err(Refusal::Account);
        }
        let token = owned(token, Refusal::Account)?;
        if token_sid(raw(&token))? != *identity.sid() {
            return Err(Refusal::Custody);
        }
        let mut primary = null_mut();
        if unsafe {
            DuplicateTokenEx(
                raw(&token),
                TOKEN_ALL_ACCESS,
                null(),
                SecurityImpersonation,
                TokenPrimary,
                &mut primary,
            )
        } == 0
        {
            return Err(Refusal::Account);
        }
        let primary = owned(primary, Refusal::Account)?;
        if token_sid(raw(&primary))? != *identity.sid() {
            return Err(Refusal::Custody);
        }
        Ok(primary)
    })();
    unsafe {
        LsaDeregisterLogonProcess(lsa);
    }
    result
}

fn identity_uid(identity: &WorkerIdentity) -> Result<u32, Refusal> {
    identity
        .username()
        .strip_prefix('u')
        .ok_or(Refusal::Account)?
        .parse()
        .map_err(|_| Refusal::Account)
}

fn profile_directory(token: HANDLE) -> Result<LocalPath, Refusal> {
    let mut path = [0_u16; 4096];
    let mut length = path.len() as u32;
    if unsafe { GetUserProfileDirectoryW(token, path.as_mut_ptr(), &mut length) } == 0
        || length < 2
        || length as usize > path.len()
    {
        return Err(Refusal::Account);
    }
    let end = path
        .iter()
        .position(|unit| *unit == 0)
        .filter(|end| *end > 0)
        .ok_or(Refusal::Account)?;
    let text = String::from_utf16(&path[..end]).map_err(|_| Refusal::Account)?;
    if !std::path::Path::new(&text).is_dir() {
        return Err(Refusal::Account);
    }
    LocalPath::parse(&text).map_err(|_| Refusal::Account)
}

/// A named job owned solely by SYSTEM. Handles may close while workers survive.
fn new_job(identity: &WorkerIdentity) -> Result<OwnedHandle, Refusal> {
    let sddl = wide("O:SYG:SYD:P(A;;0x001f003f;;;SY)");
    let mut descriptor = null_mut();
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descriptor,
            null_mut(),
        )
    } == 0
    {
        return Err(Refusal::Custody);
    }
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor,
        bInheritHandle: 0,
    };
    let name = wide(&identity.job_name());
    unsafe {
        SetLastError(0);
    }
    let handle = unsafe { CreateJobObjectW(&attributes, name.as_ptr()) };
    let existed = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
    unsafe {
        LocalFree(descriptor);
    }
    let handle = owned(handle, Refusal::Startup)?;
    if existed {
        return Err(Refusal::Custody);
    }
    system_job(&handle)?;
    let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { zeroed() };
    // No kill-on-close and no breakaway: all descendants remain in this job,
    // and a broker restart cannot kill the independently running worker.
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
    limits.BasicLimitInformation.ActiveProcessLimit = 256;
    if unsafe {
        SetInformationJobObject(
            raw(&handle),
            JobObjectExtendedLimitInformation,
            (&raw const limits).cast(),
            size_of_val(&limits) as u32,
        )
    } == 0
    {
        return Err(Refusal::Startup);
    }
    Ok(handle)
}

fn system_job(job: &OwnedHandle) -> Result<(), Refusal> {
    let mut owner = null_mut();
    let mut dacl = null_mut();
    let mut descriptor = null_mut();
    if unsafe {
        GetSecurityInfo(
            raw(job),
            SE_KERNEL_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            null_mut(),
            &mut dacl,
            null_mut(),
            &mut descriptor,
        )
    } != 0
    {
        return Err(Refusal::Custody);
    }
    let result = (|| {
        // Aligned binary S-1-5-18 (LocalSystem).
        let system = [0x00000101_u32, 0x05000000, 18];
        let system_sid = system.as_ptr().cast_mut().cast();
        let mut control = 0;
        let mut revision = 0;
        if owner.is_null()
            || dacl.is_null()
            || unsafe { EqualSid(owner, system_sid) } == 0
            || unsafe { GetSecurityDescriptorControl(descriptor, &mut control, &mut revision) } == 0
            || control & SE_DACL_PROTECTED == 0
            || unsafe { (*dacl).AceCount } != 1
        {
            return Err(Refusal::Custody);
        }
        let mut ace = null_mut();
        if unsafe { GetAce(dacl, 0, &mut ace) } == 0 || ace.is_null() {
            return Err(Refusal::Custody);
        }
        let allowed = unsafe { &*ace.cast::<ACCESS_ALLOWED_ACE>() };
        if allowed.Header.AceType != 0
            || allowed.Header.AceFlags != 0
            || allowed.Header.AceSize as usize != size_of::<ACCESS_ALLOWED_ACE>() + 8
            || allowed.Mask != JOB_ALL_ACCESS
            || unsafe { EqualSid((&raw const allowed.SidStart).cast_mut().cast(), system_sid) } == 0
        {
            return Err(Refusal::Custody);
        }
        Ok(())
    })();
    unsafe {
        LocalFree(descriptor);
    }
    result
}

fn process_identity(process: &OwnedHandle) -> Result<ProcessIdentity, Refusal> {
    let mut created: FILETIME = unsafe { zeroed() };
    let mut exit: FILETIME = unsafe { zeroed() };
    let mut kernel: FILETIME = unsafe { zeroed() };
    let mut user: FILETIME = unsafe { zeroed() };
    if unsafe {
        GetProcessTimes(
            raw(process),
            &mut created,
            &mut exit,
            &mut kernel,
            &mut user,
        )
    } == 0
    {
        return Err(Refusal::Custody);
    }
    Ok(ProcessIdentity {
        pid: unsafe { GetProcessId(raw(process)) },
        created: (u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime),
    })
}

fn peer(
    process: &OwnedHandle,
    job: &OwnedHandle,
    executable: &LocalPath,
) -> Result<PipePeer, Refusal> {
    let mut token = null_mut();
    if unsafe { OpenProcessToken(raw(process), TOKEN_QUERY, &mut token) } == 0 {
        return Err(Refusal::Custody);
    }
    let token = owned(token, Refusal::Custody)?;
    let mut path = [0_u16; 4096];
    let mut length = path.len() as u32;
    if unsafe { QueryFullProcessImageNameW(raw(process), 0, path.as_mut_ptr(), &mut length) } == 0
        || length as usize >= path.len()
    {
        return Err(Refusal::Custody);
    }
    let path = String::from_utf16(&path[..length as usize]).map_err(|_| Refusal::Custody)?;
    let mut member = 0;
    if unsafe { IsProcessInJob(raw(process), raw(job), &mut member) } == 0 {
        return Err(Refusal::Custody);
    }
    Ok(PipePeer {
        process: process_identity(process)?,
        sid: token_sid(raw(&token))?,
        in_expected_job: member != 0,
        exact_executable: path.eq_ignore_ascii_case(executable.as_str()),
    })
}

/// Trusted deployment paths, never selected from an incoming editor preface.
pub struct Package {
    pub node: LocalPath,
    pub server: LocalPath,
    pub system_root: LocalPath,
    pub worker_path: String,
    pub extra_ca_certs: LocalPath,
}

/// An owned worker. Dropping this object closes handles and leaves it running.
pub struct Worker {
    process: OwnedHandle,
    job: OwnedHandle,
    identity: WorkerIdentity,
    executable: LocalPath,
    process_identity: ProcessIdentity,
}

impl Worker {
    /// @cc [owner:ghuntley,label:security;recovery] windows-editor-suspended-account-launch
    /// Launch MUST verify the current local and S4U token SID, create the exact
    /// configured executable directly with no inherited handles, and assign its
    /// suspended process to a new SYSTEM-only job before resume. Failure MUST
    /// terminate the child. Broker handle closure MUST NOT end a resumed worker.
    pub fn launch(identity: WorkerIdentity, package: &Package) -> Result<Self, Refusal> {
        package_file(&package.node)?;
        package_file(&package.server)?;
        package_file(&package.extra_ca_certs)?;
        if package.worker_path.is_empty()
            || package.worker_path.len() > 4096
            || package.worker_path.contains(['\0', '\r', '\n'])
        {
            return Err(Refusal::Package);
        }
        privilege(SE_ASSIGNPRIMARYTOKEN_NAME)?;
        privilege(SE_INCREASE_QUOTA_NAME)?;
        privilege(SE_TCB_NAME)?;
        let token = account_token(&identity)?;
        let home = profile_directory(raw(&token))?;
        let mut command = command_line(&[
            package.node.as_str().to_owned(),
            package.server.as_str().to_owned(),
            "--without-connection-token".to_owned(),
            "--socket-path".to_owned(),
            identity.pipe_name(),
            "--server-data-dir".to_owned(),
            format!(r"{}\.overalls-code-server", home.as_str()),
            "--enable-remote-auto-shutdown".to_owned(),
            "--reconnection-grace-time".to_owned(),
            "1500".to_owned(),
            "--disable-telemetry".to_owned(),
            "--disable-workspace-trust".to_owned(),
            "--default-folder".to_owned(),
            r"C:\workspace".to_owned(),
        ])?;
        let mut pairs = vec![
            ("HOME", home.as_str().to_owned()),
            ("USERPROFILE", home.as_str().to_owned()),
            ("USERNAME", identity.username().to_owned()),
            ("SystemRoot", package.system_root.as_str().to_owned()),
            ("WINDIR", package.system_root.as_str().to_owned()),
            ("PATH", package.worker_path.clone()),
            ("APPDATA", format!(r"{}\AppData\Roaming", home.as_str())),
            ("LOCALAPPDATA", format!(r"{}\AppData\Local", home.as_str())),
            (
                "COMSPEC",
                format!(r"{}\System32\cmd.exe", package.system_root.as_str()),
            ),
            ("PATHEXT", ".COM;.EXE;.BAT;.CMD".to_owned()),
            (
                "NODE_EXTRA_CA_CERTS",
                package.extra_ca_certs.as_str().to_owned(),
            ),
            ("TEMP", format!(r"{}\AppData\Local\Temp", home.as_str())),
            ("TMP", format!(r"{}\AppData\Local\Temp", home.as_str())),
            ("OVERALLS_EDITOR_ORIGIN", identity.origin().to_owned()),
            (
                "OVERALLS_WEBVIEW_ENDPOINT_TEMPLATE",
                identity.webview_template().to_owned(),
            ),
        ];
        pairs.sort_by_key(|(key, _)| key.to_ascii_uppercase());
        let environment: Vec<u16> = pairs
            .into_iter()
            .flat_map(|(key, value)| wide(&format!("{key}={value}")))
            .chain([0])
            .collect();
        let job = new_job(&identity)?;
        let mut startup: STARTUPINFOW = unsafe { zeroed() };
        startup.cb = size_of::<STARTUPINFOW>() as u32;
        let mut desktop = wide("");
        startup.lpDesktop = desktop.as_mut_ptr();
        let application = wide(package.node.as_str());
        let directory = wide(home.as_str());
        let mut information: PROCESS_INFORMATION = unsafe { zeroed() };
        if unsafe {
            CreateProcessAsUserW(
                raw(&token),
                application.as_ptr(),
                command.as_mut_ptr(),
                null(),
                null(),
                0,
                CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW,
                environment.as_ptr().cast(),
                directory.as_ptr(),
                &startup,
                &mut information,
            )
        } == 0
        {
            return Err(Refusal::Startup);
        }
        let process = owned(information.hProcess, Refusal::Startup)?;
        let thread = owned(information.hThread, Refusal::Startup)?;
        let launched = (|| {
            if unsafe { AssignProcessToJobObject(raw(&job), raw(&process)) } == 0 {
                return Err(Refusal::Startup);
            }
            let process_identity = process_identity(&process)?;
            verify_peer(
                &identity,
                process_identity,
                &peer(&process, &job, &package.node)?,
            )?;
            if unsafe { ResumeThread(raw(&thread)) } == u32::MAX {
                return Err(Refusal::Startup);
            }
            Ok(process_identity)
        })();
        match launched {
            Ok(process_identity) => Ok(Self {
                process,
                job,
                identity,
                executable: package.node.clone(),
                process_identity,
            }),
            Err(error) => {
                unsafe {
                    TerminateProcess(raw(&process), 1);
                    TerminateJobObject(raw(&job), 1);
                    WaitForSingleObject(raw(&process), 5000);
                }
                Err(error)
            }
        }
    }

    /// Reopen only an exact retained process and SYSTEM-owned named job.
    pub fn adopt(
        identity: WorkerIdentity,
        expected: ProcessIdentity,
        executable: LocalPath,
    ) -> Result<Self, Refusal> {
        if resolve_account(identity_uid(&identity)?, identity.username())? != *identity.sid() {
            return Err(Refusal::Account);
        }
        let name = wide(&identity.job_name());
        let job = owned(
            unsafe { OpenJobObjectW(JOB_QUERY | JOB_TERMINATE | READ_CONTROL, 0, name.as_ptr()) },
            Refusal::Custody,
        )?;
        system_job(&job)?;
        let process = owned(
            unsafe {
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                    0,
                    expected.pid,
                )
            },
            Refusal::Custody,
        )?;
        verify_peer(&identity, expected, &peer(&process, &job, &executable)?)?;
        Ok(Self {
            process,
            job,
            identity,
            executable,
            process_identity: expected,
        })
    }

    pub fn process_identity(&self) -> ProcessIdentity {
        self.process_identity
    }

    /// Reopen a retained worker, distinguishing a conclusively absent process
    /// from a PID-reused or foreign process. Only the former returns `None`.
    pub fn recover(
        identity: WorkerIdentity,
        expected: ProcessIdentity,
        executable: LocalPath,
    ) -> Result<Option<Self>, Refusal> {
        if resolve_account(identity_uid(&identity)?, identity.username())? != *identity.sid() {
            return Err(Refusal::Account);
        }
        let name = wide(&identity.job_name());
        let job =
            unsafe { OpenJobObjectW(JOB_QUERY | JOB_TERMINATE | READ_CONTROL, 0, name.as_ptr()) };
        if job.is_null() {
            return match unsafe { GetLastError() } {
                ERROR_FILE_NOT_FOUND => {
                    let process = unsafe {
                        OpenProcess(
                            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                            0,
                            expected.pid,
                        )
                    };
                    if process.is_null() && unsafe { GetLastError() } == ERROR_INVALID_PARAMETER {
                        Ok(None)
                    } else {
                        if !process.is_null() {
                            unsafe { CloseHandle(process) };
                        }
                        Err(Refusal::Custody)
                    }
                }
                _ => Err(Refusal::Custody),
            };
        }
        let job = owned(job, Refusal::Custody)?;
        system_job(&job)?;
        let process = unsafe {
            OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                0,
                expected.pid,
            )
        };
        if process.is_null() {
            return match unsafe { GetLastError() } {
                ERROR_INVALID_PARAMETER => Ok(None),
                _ => Err(Refusal::Custody),
            };
        }
        let process = owned(process, Refusal::Custody)?;
        if process_identity(&process)? != expected {
            return Err(Refusal::Custody);
        }
        verify_peer(&identity, expected, &peer(&process, &job, &executable)?)?;
        Ok(Some(Self {
            process,
            job,
            identity,
            executable,
            process_identity: expected,
        }))
    }

    /// A retained process is live only when its PID and creation time remain
    /// exact and the process is still in the verified named job.
    pub fn is_running(&self) -> Result<bool, Refusal> {
        let observed = process_identity(&self.process)?;
        if observed != self.process_identity
            || unsafe {
                WaitForSingleObject(raw(&self.process), 0)
                    != windows_sys::Win32::Foundation::WAIT_TIMEOUT
            }
        {
            return Ok(false);
        }
        verify_peer(
            &self.identity,
            self.process_identity,
            &peer(&self.process, &self.job, &self.executable)?,
        )?;
        Ok(true)
    }

    /// @cc [owner:ghuntley,label:security] windows-editor-connected-pipe-custody
    /// A returned pipe MUST be connected to the exact retained worker process
    /// after kernel PID, creation-time, token-SID, executable and job checks.
    /// The open MUST permit identification only, so a foreign pipe
    /// server cannot impersonate the LocalSystem broker. Failure closes the
    /// connection without killing or deleting the possible server.
    pub fn connect(&self) -> Result<Pipe, Refusal> {
        let pipe_name = wide(&self.identity.pipe_name());
        if unsafe { WaitNamedPipeW(pipe_name.as_ptr(), 2_000) } == 0 {
            return Err(Refusal::Readiness);
        }
        let pipe = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION | FILE_FLAG_OVERLAPPED)
            .open(self.identity.pipe_name())
            .map_err(|_| Refusal::Readiness)?;
        let mut pid = 0;
        if unsafe { GetNamedPipeServerProcessId(pipe.as_raw_handle(), &mut pid) } == 0
            || pid != self.process_identity.pid
        {
            return Err(Refusal::Custody);
        }
        verify_peer(
            &self.identity,
            self.process_identity,
            &peer(&self.process, &self.job, &self.executable)?,
        )?;
        Pipe::from_file(pipe).map_err(|_| Refusal::Readiness)
    }

    /// End only the verified job; personal profile/workspace files are untouched.
    pub fn terminate(&self) -> Result<(), Refusal> {
        system_job(&self.job)?;
        verify_peer(
            &self.identity,
            self.process_identity,
            &peer(&self.process, &self.job, &self.executable)?,
        )?;
        if unsafe { TerminateJobObject(raw(&self.job), 1) } == 0
            || unsafe { WaitForSingleObject(raw(&self.process), 5000) } != WAIT_OBJECT_0
        {
            return Err(Refusal::Startup);
        }
        Ok(())
    }
}

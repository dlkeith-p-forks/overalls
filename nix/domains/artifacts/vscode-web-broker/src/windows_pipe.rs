//! Bounded overlapped I/O for the retained Windows named pipe.
//!
//! Named pipes opened with `FILE_FLAG_OVERLAPPED` MUST NOT be wrapped in a
//! blocking `std::fs::File` read/write path: an operation can otherwise keep a
//! broker thread alive after the worker disappears. `Pipe` keeps one event per
//! handle and cancels each operation at its deadline.

use std::fs::File;
use std::io::{self, Read, Write};
use std::mem::zeroed;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::ptr::{null, null_mut};
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{ERROR_IO_PENDING, HANDLE, WAIT_OBJECT_0, WAIT_TIMEOUT};
use windows_sys::Win32::Storage::FileSystem::{ReadFile, WriteFile};
use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};
use windows_sys::Win32::System::Threading::{CreateEventW, WaitForSingleObject};

const OPERATION_TIMEOUT: Duration = Duration::from_secs(30);

/// A connected named pipe with bounded overlapped reads and writes.
pub struct Pipe {
    file: File,
    event: OwnedHandle,
}

impl Pipe {
    pub fn from_file(file: File) -> io::Result<Self> {
        let event = unsafe { CreateEventW(null(), 0, 0, null()) };
        if event.is_null() || event == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: CreateEventW returned a new handle owned by this value.
        let event = unsafe { OwnedHandle::from_raw_handle(event) };
        Ok(Self { file, event })
    }

    pub fn raw_handle(&self) -> HANDLE {
        self.file.as_raw_handle()
    }

    /// Duplicate the pipe handle with an independent completion event. The
    /// relay uses one direction per clone, so sharing an OVERLAPPED event
    /// would permit one operation to consume another's completion signal.
    pub fn try_clone(&self) -> io::Result<Self> {
        Self::from_file(self.file.try_clone()?)
    }

    fn operation(
        &self,
        buffer: *mut u8,
        input: *const u8,
        length: usize,
        write: bool,
        timeout: Duration,
    ) -> io::Result<usize> {
        if length > u32::MAX as usize {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "pipe operation exceeds Win32 length",
            ));
        }
        let mut overlapped: OVERLAPPED = unsafe { zeroed() };
        overlapped.hEvent = self.event.as_raw_handle();
        let started = if write {
            // SAFETY: the caller keeps the input buffer alive until this call
            // returns, and the overlapped operation is cancelled and drained
            // before this function returns.
            unsafe {
                WriteFile(
                    self.raw_handle(),
                    input,
                    length as u32,
                    null_mut(),
                    &mut overlapped,
                )
            }
        } else {
            // SAFETY: the caller keeps the output buffer alive until this call
            // returns, and the overlapped operation is cancelled and drained
            // before this function returns.
            unsafe {
                ReadFile(
                    self.raw_handle(),
                    buffer,
                    length as u32,
                    null_mut(),
                    &mut overlapped,
                )
            }
        };
        let pending = if started == 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(ERROR_IO_PENDING as i32) {
                return Err(error);
            }
            true
        } else {
            false
        };

        // A synchronous completion does not need a kernel wait. In
        // particular, avoid waiting on an event whose signal semantics are
        // implementation-dependent for an already-completed operation.
        if !pending {
            let mut transferred = 0;
            if unsafe { GetOverlappedResult(self.raw_handle(), &overlapped, &mut transferred, 0) }
                == 0
            {
                return Err(io::Error::last_os_error());
            }
            return Ok(transferred as usize);
        }

        let timeout = timeout.as_millis().min(u32::MAX as u128) as u32;
        let wait = unsafe { WaitForSingleObject(self.event.as_raw_handle(), timeout) };
        if wait == WAIT_TIMEOUT {
            self.cancel_and_drain(&overlapped);
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "overlapped pipe operation timed out",
            ));
        }
        if wait != WAIT_OBJECT_0 {
            self.cancel_and_drain(&overlapped);
            return Err(io::Error::last_os_error());
        }
        let mut transferred = 0;
        if unsafe { GetOverlappedResult(self.raw_handle(), &overlapped, &mut transferred, 0) } == 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(transferred as usize)
    }

    fn cancel_and_drain(&self, overlapped: &OVERLAPPED) {
        // SAFETY: cancellation is scoped to this exact operation. The
        // completion is drained before the stack OVERLAPPED dies.
        unsafe {
            let _ = CancelIoEx(self.raw_handle(), overlapped);
            let mut transferred = 0;
            let _ = GetOverlappedResult(self.raw_handle(), overlapped, &mut transferred, 1);
        }
    }

    pub fn read_deadline(&mut self, buffer: &mut [u8], deadline: Instant) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let timeout = deadline.saturating_duration_since(Instant::now());
        self.operation(buffer.as_mut_ptr(), null(), buffer.len(), false, timeout)
    }

    pub fn write_deadline(&mut self, buffer: &[u8], deadline: Instant) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let timeout = deadline.saturating_duration_since(Instant::now());
        self.operation(null_mut(), buffer.as_ptr(), buffer.len(), true, timeout)
    }
}

impl Read for Pipe {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        self.operation(
            buffer.as_mut_ptr(),
            null(),
            buffer.len(),
            false,
            OPERATION_TIMEOUT,
        )
    }
}

impl Write for Pipe {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        self.operation(
            null_mut(),
            buffer.as_ptr(),
            buffer.len(),
            true,
            OPERATION_TIMEOUT,
        )
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

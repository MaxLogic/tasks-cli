//! The only unsafe surface: read-only Win32 clipboard handles and locked memory.
//! Clipboard handles belong to Windows and must never be freed by this process.
use super::*;
use std::{marker::PhantomData, os::windows::ffi::OsStringExt, ptr, rc::Rc};
use windows_sys::Win32::{
    Foundation::{GetLastError, SetLastError, HGLOBAL},
    Globalization::{MultiByteToWideChar, CP_ACP},
    System::{
        DataExchange::{
            CloseClipboard, EnumClipboardFormats, GetClipboardData, OpenClipboard,
            RegisterClipboardFormatW,
        },
        Memory::{GlobalLock, GlobalSize, GlobalUnlock},
    },
};

// Private, thread-affine guard. No raw handles or borrowed slices escape it.
struct Clipboard {
    png: u32,
    _thread: PhantomData<Rc<()>>,
}
impl Drop for Clipboard {
    fn drop(&mut self) {
        // SAFETY: constructed only after successful OpenClipboard on this thread;
        // field privacy and !Send/!Sync ensure exactly one matching close here.
        unsafe {
            CloseClipboard();
        }
    }
}

struct Locked<'a> {
    handle: HGLOBAL,
    _owner: &'a Clipboard,
}

// Keep the status and thread-local error read together: a later Win32 call can
// overwrite GetLastError. The injectable operation also permits a no-clipboard
// test of the real error-reading path.
fn open_result(open: impl FnOnce() -> i32) -> Result<(), u32> {
    // SAFETY: SetLastError operates on this thread's scalar error slot and
    // accepts every u32 value. No pointers or ownership are involved.
    unsafe { SetLastError(0) };
    if open() != 0 {
        Ok(())
    } else {
        // SAFETY: GetLastError reads this thread's scalar error slot immediately
        // after the failed operation, before another Win32 call can overwrite it.
        Err(unsafe { GetLastError() })
    }
}
impl Drop for Locked<'_> {
    fn drop(&mut self) {
        // SAFETY: this guard exists only after one successful GlobalLock. The
        // clipboard remains open for its lifetime; Windows retains ownership.
        unsafe {
            GlobalUnlock(self.handle);
        }
    }
}

pub(super) fn capture() -> Result<ClipboardCapture, ClipboardCaptureError> {
    let png_name: Vec<u16> = "PNG\0".encode_utf16().collect();
    // SAFETY: a valid, terminated UTF-16 name, read only for the duration of the
    // call. Registering a format neither opens nor modifies clipboard content.
    let png = unsafe { RegisterClipboardFormatW(png_name.as_ptr()) };
    if png == 0 {
        return Err(invalid("cannot register PNG clipboard format"));
    }
    open_with(
        || {
            open_result(|| {
                // SAFETY: NULL is explicitly supported for read-only OpenClipboard;
                // these APIs require no COM/OLE initialization or apartment. The guard
                // is created immediately on success, on this same thread.
                unsafe { OpenClipboard(ptr::null_mut()) }
            })
        },
        || std::thread::sleep(std::time::Duration::from_millis(50)),
    )?;
    let clipboard = Clipboard {
        png,
        _thread: PhantomData,
    };
    capture_source(clipboard)
}

impl Source for Clipboard {
    fn formats(&self) -> Result<Vec<Format>, ClipboardCaptureError> {
        let mut formats = Vec::new();
        let mut current = 0;
        // Win32 synthesizes CF_DIB/CF_DIBV5 for CF_BITMAP; EnumClipboardFormats
        // includes synthesized formats. No HBITMAP, GDI DC, or OLE is needed.
        for _ in 0..65536 {
            // SAFETY: clipboard is held open by self, enumeration starts at 0
            // and each subsequent value came from the immediately previous call.
            let (next, error) = unsafe {
                SetLastError(0);
                let next = EnumClipboardFormats(current);
                (next, GetLastError())
            };
            if next == 0 {
                return if error == 0 {
                    Ok(formats)
                } else {
                    Err(invalid(&format!(
                        "EnumClipboardFormats failed (Windows error {error})"
                    )))
                };
            }
            let format = match next {
                15 => Some(Format::Files),
                17 => Some(Format::DibV5),
                8 => Some(Format::Dib),
                n if n == self.png => Some(Format::Png),
                _ => None,
            };
            if let Some(format) = format {
                if !formats.contains(&format) {
                    formats.push(format);
                }
            }
            current = next;
        }
        Err(invalid("clipboard format enumeration exceeds its bound"))
    }

    fn with_data<T>(
        &self,
        format: Format,
        consume: impl FnOnce(&[u8]) -> Result<T, ClipboardCaptureError>,
    ) -> Result<T, ClipboardCaptureError> {
        let id = match format {
            Format::Files => 15,
            Format::Png => self.png,
            Format::DibV5 => 17,
            Format::Dib => 8,
        };
        // SAFETY: the clipboard is open on this thread. Only HGLOBAL-backed
        // clipboard formats are requested; we do not free the returned handle.
        let handle = unsafe { GetClipboardData(id) };
        if handle.is_null() {
            return Err(invalid(
                "GetClipboardData failed; clipboard unavailable or invalid",
            ));
        }
        // SAFETY: GetClipboardData returned an HGLOBAL for this selected format.
        let size = unsafe { GlobalSize(handle) };
        if size == 0 {
            return Err(invalid("empty or invalid clipboard allocation"));
        }
        // Bound PNG/DIB allocation before locking. File drops must be counted
        // in place before their metadata cap; never allocate GlobalSize bytes.
        check_size(format, size as u64)?;
        if size > isize::MAX as usize {
            return Err(invalid(
                "clipboard allocation exceeds the addressable slice bound",
            ));
        }
        // SAFETY: valid HGLOBAL, kept alive by the open clipboard guard.
        let pointer = unsafe { GlobalLock(handle) };
        if pointer.is_null() {
            return Err(invalid("GlobalLock failed"));
        }
        let _lock = Locked {
            handle,
            _owner: self,
        };
        // SAFETY: GlobalLock supplies a non-null allocation valid for GlobalSize
        // bytes, checked above to be <= isize::MAX. Clipboard ownership keeps
        // these bytes stable; this read-only slice is consumed before unlock and
        // close, including on early error or panic. No reference escapes consume.
        consume(unsafe { std::slice::from_raw_parts(pointer.cast::<u8>(), size) })
    }
}

pub(super) fn ansi_path(bytes: &[u8]) -> Result<PathBuf, ClipboardCaptureError> {
    // Input is bounded to 1 MiB by Source, but keep the conversion locally total.
    let count = i32::try_from(bytes.len()).map_err(|_| invalid("ANSI path too long"))?;
    // SAFETY: readable input and explicit length; NULL output with zero capacity
    // requests the UTF-16 size. No pointer is retained by Windows.
    let length =
        unsafe { MultiByteToWideChar(CP_ACP, 0, bytes.as_ptr(), count, ptr::null_mut(), 0) };
    if length <= 0 {
        return Err(invalid("cannot decode ANSI file drop"));
    }
    let mut wide = vec![0u16; length as usize];
    // SAFETY: initialized output sized by the preceding identical conversion;
    // both buffers remain valid and disjoint for the duration of the call.
    let written =
        unsafe { MultiByteToWideChar(CP_ACP, 0, bytes.as_ptr(), count, wide.as_mut_ptr(), length) };
    if written != length {
        return Err(invalid("cannot decode ANSI file drop"));
    }
    Ok(PathBuf::from(std::ffi::OsString::from_wide(&wide)))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn busy_retry_reads_the_operation_error_before_any_other_windows_call() {
        use std::cell::Cell;
        for (failures, code, expected_calls, expected_sleeps, succeeds) in [
            (2, 5, 3, 2, true),
            (4, 5, 4, 3, false),
            (1, 87, 1, 0, false),
        ] {
            let calls = Cell::new(0);
            let sleeps = Cell::new(0);
            let result = open_with(
                || {
                    open_result(|| {
                        calls.set(calls.get() + 1);
                        // SAFETY: only this thread's last-error slot changes. The test
                        // never calls OpenClipboard or any clipboard data operation.
                        unsafe {
                            SetLastError(code);
                        }
                        if calls.get() <= failures {
                            0
                        } else {
                            1
                        }
                    })
                },
                || sleeps.set(sleeps.get() + 1),
            );
            assert_eq!(result.is_ok(), succeeds);
            assert_eq!(
                (calls.get(), sleeps.get()),
                (expected_calls, expected_sleeps)
            );
        }
    }
}

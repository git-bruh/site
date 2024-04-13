pub mod constants;
pub mod util;

use std::{
    mem::ManuallyDrop,
    ops::{Deref, DerefMut},
};

/// Wrap a value, executing the `cleanup` callback when it's dropped
/// Ideally, we'd have dedicated wrapper structs to abstract away
/// the creation of `mmap`'d regions, but we keep things simple for this demo
pub struct WrappedAutoFree<T, F: FnOnce(T)> {
    val: ManuallyDrop<T>,
    cleanup: ManuallyDrop<F>,
}

impl<T, F: FnOnce(T)> WrappedAutoFree<T, F> {
    pub fn new(val: T, cleanup: F) -> Self {
        Self {
            val: ManuallyDrop::new(val),
            cleanup: ManuallyDrop::new(cleanup),
        }
    }
}

impl<T, F: FnOnce(T)> Deref for WrappedAutoFree<T, F> {
    type Target = T;

    fn deref(&self) -> &T {
        &self.val
    }
}

impl<T, F: FnOnce(T)> DerefMut for WrappedAutoFree<T, F> {
    fn deref_mut(&mut self) -> &mut T {
        &mut self.val
    }
}

impl<T, F: FnOnce(T)> Drop for WrappedAutoFree<T, F> {
    fn drop(&mut self) {
        let (cleanup, val) = unsafe {
            (
                (ManuallyDrop::<_>::take(&mut self.cleanup)),
                (ManuallyDrop::<_>::take(&mut self.val)),
            )
        };

        (cleanup)(val);
    }
}

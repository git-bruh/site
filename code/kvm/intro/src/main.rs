use intro::WrappedAutoFree;
use kvm_bindings::{
    kvm_regs, kvm_run, kvm_sregs, kvm_userspace_memory_region, KVMIO, KVM_EXIT_HLT, KVM_EXIT_IO,
};
use nix::{
    fcntl,
    fcntl::OFlag,
    ioctl_read, ioctl_write_int_bad, ioctl_write_ptr, request_code_none,
    sys::{mman, mman::MapFlags, mman::ProtFlags, stat::Mode},
};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::{env, fs::File, io::Read, num::NonZeroUsize, os::fd::BorrowedFd};

ioctl_write_int_bad!(kvm_create_vm, request_code_none!(KVMIO, 0x01));
ioctl_write_int_bad!(kvm_get_vcpu_mmap_size, request_code_none!(KVMIO, 0x04));
ioctl_write_int_bad!(kvm_run, request_code_none!(KVMIO, 0x80));
ioctl_write_int_bad!(kvm_create_vcpu, request_code_none!(KVMIO, 0x41));
ioctl_write_ptr!(
    kvm_set_user_memory_region,
    KVMIO,
    0x46,
    kvm_userspace_memory_region
);
ioctl_read!(kvm_get_regs, KVMIO, 0x81, kvm_regs);
ioctl_write_ptr!(kvm_set_regs, KVMIO, 0x82, kvm_regs);
ioctl_read!(kvm_get_sregs, KVMIO, 0x83, kvm_sregs);
ioctl_write_ptr!(kvm_set_sregs, KVMIO, 0x84, kvm_sregs);

struct Kvm {
    /// KVM subsystem handle
    kvm: OwnedFd,
    /// VM handle
    vm: OwnedFd,
    /// vCPU handle
    vcpu: OwnedFd,
    /// Shared kvm_run structure for communication
    kvm_run: WrappedAutoFree<*mut kvm_run, Box<dyn FnOnce(*mut kvm_run)>>,
}

impl Kvm {
    pub fn new() -> Result<Self, std::io::Error> {
        let kvm =
            unsafe { OwnedFd::from_raw_fd(fcntl::open("/dev/kvm", OFlag::O_RDWR, Mode::empty())?) };
        let vm = unsafe { OwnedFd::from_raw_fd(kvm_create_vm(kvm.as_raw_fd(), 0)?) };
        let vcpu = unsafe { OwnedFd::from_raw_fd(kvm_create_vcpu(vm.as_raw_fd(), 0)?) };

        // Size of the shared `kvm_run` mapping
        let mmap_size = NonZeroUsize::new(unsafe {
            kvm_get_vcpu_mmap_size(kvm.as_raw_fd(), 0)?
                .try_into()
                .expect("mmap_size too big for usize!")
        })
        .expect("mmap_size is zero");

        let kvm_run = WrappedAutoFree::new(
            unsafe {
                mman::mmap(
                    None,
                    mmap_size,
                    ProtFlags::PROT_READ | ProtFlags::PROT_WRITE,
                    MapFlags::MAP_SHARED,
                    Some(&vcpu),
                    0,
                )? as *mut kvm_run
            },
            Box::new(move |map: *mut kvm_run| unsafe {
                mman::munmap(map as _, mmap_size.get()).expect("failed to unmap kvm_run!");
            }) as _,
        );

        Ok(Self {
            kvm,
            vm,
            vcpu,
            kvm_run,
        })
    }

    pub fn set_user_memory_region(
        &self,
        guest_phys_addr: u64,
        memory_size: usize,
        userspace_addr: u64,
    ) -> Result<(), std::io::Error> {
        unsafe {
            kvm_set_user_memory_region(
                self.vm.as_raw_fd(),
                &kvm_userspace_memory_region {
                    slot: 0,
                    flags: 0,
                    guest_phys_addr,
                    memory_size: memory_size as u64,
                    userspace_addr,
                },
            )?;
        }

        Ok(())
    }

    pub fn get_vcpu_sregs(&self) -> Result<kvm_sregs, std::io::Error> {
        let mut sregs = kvm_sregs::default();
        unsafe { kvm_get_sregs(self.vcpu.as_raw_fd(), &mut sregs)? };

        Ok(sregs)
    }

    pub fn set_vcpu_sregs(&self, regs: *const kvm_sregs) -> Result<(), std::io::Error> {
        unsafe { kvm_set_sregs(self.vcpu.as_raw_fd(), regs)? };

        Ok(())
    }

    pub fn get_vcpu_regs(&self) -> Result<kvm_regs, std::io::Error> {
        let mut regs = kvm_regs::default();
        unsafe { kvm_get_regs(self.vcpu.as_raw_fd(), &mut regs)? };

        Ok(regs)
    }

    pub fn set_vcpu_regs(&self, regs: *const kvm_regs) -> Result<(), std::io::Error> {
        unsafe { kvm_set_regs(self.vcpu.as_raw_fd(), regs)? };

        Ok(())
    }

    pub fn run(&self) -> Result<*const kvm_run, std::io::Error> {
        unsafe {
            kvm_run(self.vcpu.as_raw_fd(), 0)?;
        }

        // The `kvm_run` struct is filled with new data as it was associated
        // with the `vcpu` FD in the mmap() call
        Ok(*self.kvm_run as _)
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // We don't need a large mapping as our code is tiny
    // Must be page-size aligned, so minimum is 4KiB
    const MAP_SIZE: usize = 0x1000;

    let mut code = Vec::new();

    // Read the passed file into the `code` buffer
    File::open(env::args().nth(1).expect("no argument passed"))?.read_to_end(&mut code)?;

    let kvm = Kvm::new()?;

    // Mapping to store the code
    // MAP_ANONYMOUS is used as we're not backing this mapping by any fd
    let mapping = WrappedAutoFree::new(
        unsafe {
            mman::mmap(
                None,
                NonZeroUsize::new(MAP_SIZE).expect("mapping size is zero"),
                ProtFlags::PROT_READ | ProtFlags::PROT_WRITE,
                MapFlags::MAP_ANONYMOUS | MapFlags::MAP_SHARED,
                None::<BorrowedFd>,
                0,
            )?
        },
        |map| unsafe {
            mman::munmap(map, MAP_SIZE).expect("failed to unmap user memory region");
        },
    );

    assert!(code.len() < MAP_SIZE);

    // The idiomatic way is to write a wrapper struct for `mmap`-ing regions
    // and exposing it as a slice (std::slice::from_raw_parts)
    // But we just copy the code directly here
    unsafe {
        std::ptr::copy_nonoverlapping(code.as_ptr(), *mapping as *mut _, code.len());
    };

    let mut sregs = kvm.get_vcpu_sregs()?;

    // CS points to the reset vector by default
    sregs.cs.base = 0;
    sregs.cs.selector = 0;

    kvm.set_vcpu_sregs(&sregs)?;
    kvm.set_user_memory_region(0, MAP_SIZE, *mapping as u64)?;
    kvm.set_vcpu_regs(&kvm_regs {
        // The first bit must be set on x86
        rflags: 1 << 1,
        // The instruction pointer is set to 0 as our code is loaded with 0
        // as the base address
        rip: 0,
        ..Default::default()
    })?;

    loop {
        let kvm_run = kvm.run()?;

        unsafe {
            match (*kvm_run).exit_reason {
                KVM_EXIT_HLT => break,
                KVM_EXIT_IO => {
                    let port = (*kvm_run).__bindgen_anon_1.io.port;
                    let offset = (*kvm_run).__bindgen_anon_1.io.data_offset as usize;
                    let character = *((kvm_run as *const u8).add(offset)) as char;

                    println!("Port: {port:#x}, Char: {character}");
                }
                reason => panic!("Unhandled exit reason: {reason}"),
            }
        }
    }

    Ok(())
}

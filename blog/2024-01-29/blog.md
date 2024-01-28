# Building a hypervisor, 1: KVM Introduction

In this series of blog posts, we'll build a KVM-based hypervisor from scratch, eventually making it boot the Linux kernel. The first post will go over a "hello world" KVM example in Rust, and assumes basic systems programming knowledge (writing trivial assembly, using syscalls, ioctl's, etc.)

# The KVM API

The KVM API basically allows us to execute code under a virtualized environment, and emulate the required hardware. It is assisted by the hardware, so we can't virtualize code built for another CPU architecture. The whole KVM subsystem is centered around `ioctl` calls, which are a bit boilerplate-y to write by hand in Rust (due to error handling), so we'll use the `nix` crate's [`ioctl` helpers](https://docs.rs/nix/latest/nix/sys/ioctl/).

The flow for running a VM goes like this:

1. Obtain a handle to the KVM subsystem (`/dev/kvm`)

2. Issue a `KVM_CREATE_VM` ioctl on the handle to obtain a VM handle, i.e. a VM with no memory or vCPUs

3. Issue a `KVM_CREATE_VCPU` ioctl on the VM handle to obtain a vCPU handle, responsible for actually executing the code

4. Associate a shared memory region for communication with the guest, to the vCPU handle (`KVM_GET_VCPU_MMAP_SIZE` + `mmap`)

5. Associate another memory region with the guest containing the code to be executed, using the `KVM_SET_USER_MEMORY_REGION` ioctl

6. Setup the guest's vCPU registers to execute the code, making progress on the execution by issuing the `KVM_RUN` ioctl

```
            vCPU
          /
KVM -> VM
          \
            Memory
```

Now, coming to making `ioctl` calls, one would just call `ioctl()` with the appropriate arguments in C (error-checking ommited):

```c
int kvm = open("/dev/kvm", O_RDWR);
int vm = ioctl(kvm, KVM_CREATE_VM, 0);
```

In Rust, the aforementioned `ioctl` helpers allow us to generate a wrapper for these calls, including error handling. Refer to [`linux/kvm.h`](https://github.com/torvalds/linux/blob/8a696a29c6905594e4abf78eaafcb62165ac61f1/include/uapi/linux/kvm.h#L886) for the request code:

```rs
ioctl_write_int_bad!(kvm_create_vm, request_code_none!(KVMIO, 0x01));
```

This will generate the `kvm_create_vm` function that checks `errno` for errors and allows us to cleanly propagate them. We can similarly generate wrappers for all the other `ioctl` calls we dicussed before:

```rs
ioctl_write_int_bad!(kvm_get_vcpu_mmap_size, request_code_none!(KVMIO, 0x04));
ioctl_write_int_bad!(kvm_run, request_code_none!(KVMIO, 0x80));
ioctl_write_int_bad!(kvm_create_vcpu, request_code_none!(KVMIO, 0x41));
ioctl_write_ptr!(
    kvm_set_user_memory_region,
    KVMIO,
    0x46,
    kvm_userspace_memory_region
);
ioctl_write_ptr!(kvm_set_regs, KVMIO, 0x82, kvm_regs);
ioctl_read!(kvm_get_sregs, KVMIO, 0x83, kvm_sregs);
ioctl_write_ptr!(kvm_set_sregs, KVMIO, 0x84, kvm_sregs);
```

We use the C structs like `kvm_userspace_memory_region` from the [`kvm_bindings`](https://docs.rs/kvm-bindings/latest/kvm_bindings) crate, which is generated using [`bindgen`](https://crates.io/crates/bindgen).

# Building the abstractions

Now, we can define a `Kvm` struct to provide an abstraction for setting up the VM:

```rs
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
```

Here, `kvm`, `vm` and `vcpu` are just file descriptors, which are wrapped with the [`OwnedFd`](https://doc.rust-lang.org/std/os/fd/struct.OwnedFd.html) abstraction, which closes the FDs automatically on being dropped. Similarly, the `mmap`'d `kvm_run` region is wrapped with a custom [`WrappedAutoFree`](https://github.com/git-bruh/site/blob/master/code/kvm/intro/src/lib.rs#L9) abstraction, which unmaps the region on being dropped (with a cleanup callback)

Now, we can implement the `new` function to perform the basic setup, covering steps 1 to 4 described in the previous section:

```rs
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

    Ok(Self { kvm, vm, vcpu, kvm_run })
}
```

We obtain the `kvm`, `vm`, and `vcpu` handles using the wrappers described before, and converting them to `OwnedFd`s. Then, we get the size of the region to be mapped for the `kvm_run` structure from the kernel, and `mmap` it, associating it with the `vcpu` file descriptor.

For step 5, we have a wrapper for setting the code-containing memory region, `set_user_memory_region`:

```rs
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
```

- `guest_phys_addr`: Since this mapping will be presented as "physical" memory to the guest, this field refers to the address where it will be placed. For example, setting this to `0x1000` will make the mapping accessible at physical address `0x1000` in the guest

- `memory_size`: The size of the mapping

- `userspace_addr`: The address of the mapping in the current process (virtual address)

Finally, for step 6, we define a few tiny helpers:

- `get_vcpu_sregs`: Fetches the vCPU's special registers, pre-filled with defaults, which we later modify. This consists of [segment registers](https://wiki.osdev.org/CPU_Registers_x86#Segment_Registers), [control registers](https://wiki.osdev.org/CPU_Registers_x86#Control_Registers) and a couple more - [`kvm_sregs`](https://docs.rs/kvm-bindings/latest/kvm_bindings/struct.kvm_sregs.html)

```rs
pub fn get_vcpu_sregs(&self) -> Result<kvm_sregs, std::io::Error> {
    let mut sregs = kvm_sregs::default();
    unsafe { kvm_get_sregs(self.vcpu.as_raw_fd(), &mut sregs)? };

    Ok(sregs)
}
```

- `set_vcpu_sregs`: Sets the vCPU's special registers

```rs
pub fn set_vcpu_sregs(&self, regs: *const kvm_sregs) -> Result<(), std::io::Error> {
    unsafe { kvm_set_sregs(self.vcpu.as_raw_fd(), regs)? };

    Ok(())
}
```

- `set_vcpu_regs`: We don't define a `get_vcpu_regs` here as we don't need to fetch them for now. `regs` refers to the general-purpose CPU registers like the instruction pointer (`rip`) - [`kvm_regs`](https://docs.rs/kvm-bindings/latest/kvm_bindings/struct.kvm_regs.html)

```rs
pub fn set_vcpu_regs(&self, regs: *const kvm_regs) -> Result<(), std::io::Error> {
    unsafe { kvm_set_regs(self.vcpu.as_raw_fd(), regs)? };

    Ok(())
}
```

- `run`: Actually makes progress on the execution of the VM, issuing the `KVM_RUN` ioctl. Relevant information is filled in the `kvm_run` structure, and the control is returned back to the VMM whenever a `VMexit` occurs; so when a guest writes to a serial port, the structure will contain information like the port and the data to be written to it

```rs
pub fn run(&self) -> Result<*const kvm_run, std::io::Error> {
    unsafe { kvm_run(self.vcpu.as_raw_fd(), 0)?; }

    // The `kvm_run` struct is filled with new data as it was associated
    // with the `vcpu` FD in the mmap() call
    Ok(*self.kvm_run as _)
}
```

**NOTE:** The dereference operator might seem a bit confusing here. We use it to get the actual pointer to the structure out of the [`WrappedAutoFree`](https://github.com/git-bruh/site/blob/master/code/kvm/intro/src/lib.rs#L23) object, which implements the [`Deref` trait](https://doc.rust-lang.org/std/ops/trait.Deref.html).

# Driver code

Now, we can finally write the code to drive this VM! At this stage, the VM will run in [real mode](https://en.wikipedia.org/wiki/Real_mode), which means we can access the "physical" memory directly, and only execute 16-bit code:

```rs
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
                KVM_EXIT_IO => { /* Handle IO here */ }
                reason => panic!("Unhandled exit reason: {reason}"),
            }
        }
    }

    Ok(())
}
```

We accept a path to the compiled 16-bit real mode program as the first argument, and copy it into the shared mapping. The size of the mapping can be relatively small as our code won't do much, but it must be aligned to the page-size, which is 4KiB. Then, we fetch the special registers, and make the code segment point to address 0, rather than the [reset vector](https://en.wikipedia.org/wiki/Reset_vector). The general-purpose registers are all set to defaults (zero), except for [`rflags`](https://en.wikipedia.org/wiki/FLAGS_register), which has the 1st reserved bit set, and the instruction pointer (`rip`) also holds 0, as our code is present at physical address 0.

Finally, we have a loop to repeatedly issue the `KVM_RUN` ioctl. Whenever a `VMexit` is generated, we get back some information in the shared `kvm_run` mapping (as mentioned before), which we can use to emulate the behaviour of a physical device for the guest. The `exit_reason` tells us what exactly prompted a `VMexit`, but we only care about two constants here, treating any other value as an error:

- `KVM_EXIT_HLT` - The guest executed the [`hlt`](https://en.wikipedia.org/wiki/HLT_(x86_instruction)) instruction, which we can use as an indication to stop the VM

- `KVM_EXIT_IO` - The guest performed some I/O on a serial port, we will implement a handler for this in the next section

# Some assembly required

Now, we will write a simple 16-bit assembly program to print the string `Hello, KVM!`:

```nasm
; Output to port 0x3f8
mov dx, 0x3f8

; Store the address of the message in bx, so we can increment it
mov bx, message

loop:
    ; Load a byte from `bx` into the `al` register
    mov al, [bx]

    ; Jump to the `hlt` instruction if we encountered the NUL terminator
    cmp al, 0
    je end

    ; Output to the serial port
    out dx, al
    ; Increment `bx` by one byte to point to the next character
    inc bx

    jmp loop

end:
    hlt

message:
    db "Hello, KVM!", 0
```

Build it with `nasm -fbin hello.S -o hello`

Now, every time we hit the `out` instruction, it will generate a `VMexit`, and we'll be able to print out the character:

```diff
         unsafe {
             match (*kvm_run).exit_reason {
                 KVM_EXIT_HLT => break,
-                KVM_EXIT_IO => { /* Handle IO here */ }
+                KVM_EXIT_IO => {
+                    let port = (*kvm_run).__bindgen_anon_1.io.port;
+                    let offset = (*kvm_run).__bindgen_anon_1.io.data_offset as usize;
+                    let character = *((kvm_run as *const u8).add(offset)) as char;
+
+                    println!("Port: {port:#x}, Char: {character}");
+                }
                 reason => panic!("Unhandled exit reason: {reason}"),
             }
         }
```

Accessing [`kvm_run`](https://docs.rs/kvm-bindings/latest/kvm_bindings/struct.kvm_run.html) without any abstractions is quite unwieldy. The `__bindgen_anon_*` fields are generated by bindgen as anonymous unions cannot be represented in the same manner in Rust as they are in C, since only one field can be active at a time.

The `io.port` field tells us the target port, and `io.data_offset` gives us the offset into the `kvm_run` mapping where we can find the written byte, which we use to perform some pointer arithmetic to get the final result:

```rs
$ cargo run -- hello
    Finished dev [unoptimized + debuginfo] target(s) in 0.01s
     Running `target/debug/intro hello`
Port: 0x3f8, Char: H
Port: 0x3f8, Char: e
Port: 0x3f8, Char: l
Port: 0x3f8, Char: l
Port: 0x3f8, Char: o
Port: 0x3f8, Char: ,
Port: 0x3f8, Char:  
Port: 0x3f8, Char: K
Port: 0x3f8, Char: V
Port: 0x3f8, Char: M
Port: 0x3f8, Char: !
```

Now obviously, there is quite a bit of overhead when emulating hardware in this manner, as every interaction will cause a `VMexit`. [`virtio` devices](https://docs.kernel.org/driver-api/virtio/virtio.html) are much more efficient, though we won't be covering them in this post.

# Conclusion

In this post, we covered a small overview of the Linux KVM API, and implemented a hello-world esque hypervisor. In the next posts, we'll be exploring long mode, paging, and implementing the Linux boot protocol to boot a small Linux kernel image.

# Resources

https://github.com/rust-vmm

https://www.kernel.org/doc/html/latest/virt/kvm/api.html

https://lwn.net/Articles/658511/

https://david942j.blogspot.com/2018/10/note-learning-kvm-implement-your-own.html

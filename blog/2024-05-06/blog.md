# Building a hypervisor, 2: Booting Linux

In this post, we'll make our hypervisor boot the Linux kernel into a basic userspace consisting of a dummy `init`, covering topics like long mode, paging, the Linux boot protocol, and various KVM APIs

This post will touch on a lot of topics briefly, but won't go super in-depth into all of them, mainly focusing on the blockers I faced personally as a novice systems programmer

# Linux Boot Protocol

The [Linux Boot Protocol](https://www.kernel.org/doc/html/latest/arch/x86/boot.html) describes setting up the environment for booting the kernel, involving loading the kernel image, passing kernel command line arguments & other setup parameters, setting up segment registers, etc. laying out everything in memory like so:

```
        |                        |
0A0000  +------------------------+
        |  Reserved for BIOS     |      Do not use.  Reserved for BIOS EBDA.
09A000  +------------------------+
        |  Command line          |
        |  Stack/heap            |      For use by the kernel real-mode code.
098000  +------------------------+
        |  Kernel setup          |      The kernel real-mode code.
090200  +------------------------+
        |  Kernel boot sector    |      The kernel legacy boot sector.
090000  +------------------------+
        |  Protected-mode kernel |      The bulk of the kernel image.
010000  +------------------------+
        |  Boot loader           |      <- Boot sector entry point 0000:7C00
001000  +------------------------+
        |  Reserved for MBR/BIOS |
000800  +------------------------+
        |  Typically used by MBR |
000600  +------------------------+
        |  BIOS use only         |
000000  +------------------------+
```

The kernel can be booted from real mode, protected mode, long mode, or from the UEFI directly with EFI stub (not relevant here). In long mode, the bootloader itself has to setup paging, various flags in registers, etc. which the kernel would do by itself if booted in real mode, but we opt for long mode here as this setup will be required when we modify our code to boot an uncompressed `vmlinux` image directly rather than a compressed `bzImage`, hence skipping quite a bit of startup code. This is also done by projects like [Firecracker](https://github.com/firecracker-microvm/firecracker)

We will be covering these topics briefly first, before finally getting to boot the kernel image

# Paging

First, we'll enter long mode, execute 64-bit code under it, and then come back to the Linux boot protocol. In the [previous post](/2024-01-29.html), we setup a basic environment using the KVM API capable of executing 16-bit real mode code and executed a toy program under it:

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

From the [64-bit boot protocol](https://www.kernel.org/doc/html/latest/arch/x86/boot.html#id1), `At entry, the CPU must be in 64-bit mode with paging enabled. The range with setup_header.init_size from start address of loaded kernel and zero page and command line buffer get ident mapping; a GDT must be loaded with the descriptors for selectors __BOOT_CS(0x10) and __BOOT_DS(0x18); both descriptors must be 4G flat segment; __BOOT_CS must have execute/read permission, and __BOOT_DS must have read/write permission; CS must be __BOOT_CS and DS, ES, SS must be __BOOT_DS; interrupt must be disabled; %rsi must hold the base address of the struct boot_params` - So we have a couple of things to do:

- Setup Paging (prerequisite for long mode)

- Enter Long Mode

- Setup Segment Registers

We just need to perform a basic paging setup as mentioned above, involving identity mapped pages, i.e. virtual addresses in a specific range are mapped to the same physical addresses, for instance, the virtual address `0x200000` gets mapped to the same physical address `0x200000`. We will do this for the kernel image (the aformentioned _ident mapping_), and it's required as physical memory can't be accessed directly with paging enabled

For entering long mode, we also need to enable Physical Address Extension (PAE), implying 4 levels of page tables, each having a maximum of 512 entries:

- `PML4`: Page Map Level 4
- `PDPT`: Page Directory Pointer Table
- `PD`: Page Directory
- `PT`: Final level page table, will be omitted in our case as our PD entries will point to a page directly

```
                             [0]   = 0x000000 - 0x200000
                           / 
PML4[0] -> PDPT[0] -> PD -   [1]   = 0x200000 - 0x400000
                           \
                             [511] = 0x3fe00000 - 0x40000000
```

Note that this is a very minimal setup, just enough to satisfy the kernel's requirement of an identity mapped region and a lot more entries will be added into these tables after it boots. Further resources about paging are linked at the end, but as an example (the process might feel a bit redundant here as we're just using identity paging), the address `0x401000` would be translated by breaking up the address into ranges of bits, and using them as indices into the various tables:

```
addr = 0x401000

0000 0000 0000 0000 0000 0000 0100 0000 0001 0000 0000 0000
|PML4      |PDPT      |PD        |Offset                  |
|47 - 39   |38 - 30   |29 - 21   |20 - 0                  |

PML4 = { [0] = PDPT }
PDPT = { [0] = PD }
PD   = { [0] = 0x000000, [1] = 0x200000, ..., [511] = 0x3fe00000 }

Page Offset = addr & 0x1FFFF       = 4096
PD   Index  = (addr >> 21) & 0x1FF = 2
PDPT Index  = (addr >> 30) & 0x1FF = 0
PML4 Index  = (addr >> 39) & 0x1FF = 0
```

- The first 21 bits represent the offset into the page, the next 9 bits the index into the Page Directory, and so on (_ref. Figure 4.9 from Intel SDM Vol 3_)

- For retrieving the physical address, the PML4 index is used to fetch the entry from the `cr4` register where the PML4 table's address is stored. Here this index is 0, and that entry points to the PDPT

- Then, the PDPT index fetches the entry from the Page Directory Pointer Table, which is again at the 0'th index, pointing to the start of the PD

- Finally, the PD index fetches the entry from the Page Directory which points to the physical address of the page, here it is `2` which points to the `0x400000`. The Page Offset represents the offset into this page, which is 4096 (`0x1000`) here, so the final address is `0x400000 + 0x1000`

Coming to code, the paging setup can be implemented like this, building on top of what we developed in the previous post:

```rs
pub mod PageTables {
    /// Page Map Level 4 Table
    pub const PML4: usize = 0x1000;
    /// Page Directory Pointer Table
    pub const PDPT: usize = 0x2000;
    /// Page Directory
    pub const PD: usize = 0x3000;
}

pub mod PageFlags {
    /// The page is present in physical memory
    pub const PRESENT: u64 = 1 << 0;
    /// The page is read/write
    pub const READ_WRITE: u64 = 1 << 1;
    /// Make PDE map to a 4MiB page, Page Size Extension must be enabled
    pub const PAGE_SIZE: u64 = 1 << 7;
}

pub fn setup_paging(memory: &mut [u64]) {
    // We divide all the addresses by 8 as we treat the KVM's memory region as
    // a buffer of u64's rather than u8's in this function
    let entry_size = mem::size_of::<u64>();

    memory[PageTables::PML4 / entry_size] =
        PageFlags::PRESENT | PageFlags::READ_WRITE | PageTables::PDPT as u64;
    memory[PageTables::PDPT / entry_size] =
        PageFlags::PRESENT | PageFlags::READ_WRITE | PageTables::PD as u64;

    // We need 512 entries to cover 1GB
    let pd = &mut memory[(PageTables::PD / entry_size)..][..512];

    // Identity Mapping
    for (n, entry) in pd.iter_mut().enumerate() {
        *entry =
            PageFlags::PRESENT | PageFlags::READ_WRITE | PageFlags::PAGE_SIZE | ((n as u64) << 21);
    }
}
```

We choose page-aligned addresses for the tables, and setup entries in each of them pointing to the next level table. In the Page Directory entries, we also set the `PAGE_SIZE` flag to indicate that the next level page table is omitted and the entry points to a 2MB (contrary to 4MB mentioned in the comment, as we will also enable `PAE`) physical page directly

Bits 0-12 in the entry are reserved for flags, and 12-31 are used to represent the address, so we `OR` the flags with the entry's index shifted by 21 bits, as it gets us multiples of 2MB (eg `1 << 21 = 2097152`), hence covering 1GB with 512 entries. This doesn't interfere with the flag bits as the lower bits in our addresses are zero, and the entry only needs bits 31-12 of the address.

# Segment Registers and Long Mode

The kernel requires a Global Descriptor Table (GDT) and segment registers to be set up as we mentioned above. They are mostly relevant for memory segmentation, which is not relevant as we're using paging, but we still need a minimal setup consisting of a code segment & data segment located at `0x10` and `0x18` respectively:

```rs
/// Read permission & Data Segment is implied
/// Code Segment is implicitly executable
pub mod SegmentFlags {
    /// Read permissions for Code Segment
    pub const CODE_READ: u8 = 1 << 1;
    /// Indicate that this is a Code Segment
    pub const CODE_SEGMENT: u8 = 1 << 3;
    /// Write permissions for Data Segment
    pub const DATA_WRITE: u8 = 1 << 1;
}

/// CS, placed at 0x10
pub const CODE_SEGMENT: kvm_segment = kvm_segment {
    base: 0,
    limit: 0xFFFFFFFF,
    selector: 0x10,
    type_: SegmentFlags::CODE_SEGMENT | SegmentFlags::CODE_READ,
    present: 1,
    dpl: 0,
    db: 0,
    s: 1,
    l: 1,
    g: 1,
    avl: 0,
    unusable: 0,
    padding: 0,
};

/// DS, placed at 0x18
pub const DATA_SEGMENT: kvm_segment = kvm_segment {
    base: 0,
    limit: 0xFFFFFFFF,
    selector: 0x18,
    type_: SegmentFlags::DATA_WRITE,
    present: 1,
    dpl: 0,
    db: 1,
    s: 1,
    l: 0,
    g: 1,
    avl: 0,
    unusable: 0,
    padding: 0,
};
```

We use the `kvm_segment` as a convenient way to define these segments, but we also need to encode the segments into a 64-bit value to write to the KVM memory at the addresses set in the `selector` field (_ref Section 3.4.5 from Intel SDM Vol. 3_):

```rs
pub fn pack_segment(segment: &kvm_segment) -> u64 {
    // We don't need to set a base address
    assert_eq!(segment.base, 0);

    // Bits 8 (Segment Type) .. 15 (P)
    let lo_flags =
        // 8 .. 11 (Segment Type)
        segment.type_
        // 12 (S, Descriptor Type)
        // It is set to indicate a code/data segment
        | (segment.s << 4)
        // 13 .. 14 (Descriptor Privilege Level)
        // Leave it as zeroes for ring 0
        | (segment.dpl << 5)
        // 15 (P, Segment-Present)
        // The segment is present (duh)
        | (segment.present << 7);

    // Bits 20 (AVL) .. 23 (G)
    let hi_flags =
        // 20 (AVL)
        // Available for use by system software, undesirable in our case
        segment.avl
        // 21 (L)
        // Code segment is executed in 64-bit mode
        // For DS, L bit must not be set
        | (segment.l << 1)
        // 22 (D/B)
        // Indicates 32-bit, must only be set for DS
        // For CS, if the L-bit is set, then the D-bit must be cleared
        | (segment.db << 2)
        // 23 (G, Granularity)
        // Scales the limit to 4-KByte units, so we can set the limit to 4GB
        // while just occupying 20 bits overall
        // (0xFFFFF * (1024 * 4)) == ((1 << 20) << 12) == (1 << 32) == 4GB
        | (segment.g << 3);

    let packed =
        // 0 .. 8 (Base Addr, zero)
        // 8 .. 15
        ((lo_flags as u64) << 8)
        // 16 .. 19 (Top 4 bits of limit)
        // Can also be written as `segment.limit & 0xF0000`
        | ((segment.limit as u64 & 0xF) << 16)
        // 20 .. 23
        | ((hi_flags as u64) << 20);

    // 24 .. 31, 32 .. 46 (Base Addr, zero)
    // 47 .. 64 (Bottom 16 bits of limit)
    (packed << 32) | (segment.limit as u64 >> 16)
}

/// Sets up the GDT according in the KVM memory region
pub fn setup_gdt(memory: &mut [u64]) {
    // CS (0x10)
    memory[2] = pack_segment(&CODE_SEGMENT);
    // DS (0x18)
    memory[3] = pack_segment(&DATA_SEGMENT);
}
```

The comments in the above function also elaborate on each of the flags we set. Coming to the kernel's requirements: `a GDT must be loaded with the descriptors for selectors __BOOT_CS(0x10) and __BOOT_DS(0x18); both descriptors must be 4G flat segment; __BOOT_CS must have execute/read permission, and __BOOT_DS must have read/write permission; CS must be __BOOT_CS and DS, ES, SS must be __BOOT_DS`

We satisfy them as Code Segment is loaded at `0x10` and Data Segment at `0x18`, along with the requested permissions, and `limit` is set to 4GB with the `granularity` flag

Finally, for entering long mode, we just need to point the `cr3` register to our PML4 table's address as discussed in the previous section, and set the relevant flags in various registers:

```rs
/// Control Register 0
pub mod Cr0Flags {
    /// Enable protected mode
    pub const PE: u64 = 1 << 0;
    /// Enable paging
    pub const PG: u64 = 1 << 31;
}

/// Control Register 4
pub mod Cr4Flags {
    /// Page Size Extension
    pub const PSE: u64 = 1 << 4;
    /// Physical Address Extension, size of large pages is reduced from
    /// 4MiB to 2MiB and PSE is enabled regardless of the PSE bit
    pub const PAE: u64 = 1 << 5;
}

/// Extended Feature Enable Register
pub mod EferFlags {
    /// Long Mode Enable
    pub const LME: u64 = 1 << 8;
    /// Long Mode Active
    pub const LMA: u64 = 1 << 10;
}

/// Setup the KVM segment registers in accordance with our paging & GDT setup
pub fn setup_sregs() -> kvm_sregs {
    kvm_sregs {
        // https://wiki.osdev.org/Setting_Up_Long_Mode
        cr3: PageTables::PML4 as u64,
        cr4: Cr4Flags::PAE,
        cr0: Cr0Flags::PE | Cr0Flags::PG,
        efer: EferFlags::LMA | EferFlags::LME,
        // `limit` is not required
        // The GDT starts at address 0
        // CS is at 16 (0x10), DS is at 24 (0x18)
        gdt: kvm_dtable {
            base: 0,
            ..Default::default()
        },
        cs: CODE_SEGMENT,
        ds: DATA_SEGMENT,
        es: DATA_SEGMENT,
        fs: DATA_SEGMENT,
        gs: DATA_SEGMENT,
        ss: DATA_SEGMENT,
        ..Default::default()
    }
}

/// Setup the KVM CPU registers in accordance with the Linux boot protocol
pub fn setup_regs(code64_start: u64, boot_params_addr: u64) -> kvm_regs {
    kvm_regs {
        // Just set the reserved bit, leave all other bits off
        // This turns off interrupts as well
        rflags: 1 << 1,
        // The instruction pointer should point to the start of the 64-bit kernel code
        rip: code64_start,
        // The `rsi` register must contain the address of the `boot_params` struct
        rsi: boot_params_addr,
        ..Default::default()
    }
}
```

Let's patch up our old `main` function to call all these helpers:

```diff
diff --git a/../intro/src/main.rs b/src/main.rs
index 315f4a9..0dbadf3 100644
--- a/../intro/src/main.rs
+++ b/src/main.rs
@@ -136,9 +136,10 @@ impl Kvm {
 }
 
 fn main() -> Result<(), Box<dyn std::error::Error>> {
-    // We don't need a large mapping as our code is tiny
-    // Must be page-size aligned, so minimum is 4KiB
-    const MAP_SIZE: usize = 0x1000;
+    // 1GB
+    const MAP_SIZE: usize = 0x40000000;
+    // Arbritary (within the 1GB that we identity map)
+    const CODE_START: usize = 0x4000;
 
     let mut code = Vec::new();
 
@@ -165,31 +166,25 @@ fn main() -> Result<(), Box<dyn std::error::Error>> {
         },
     );
 
-    assert!(code.len() < MAP_SIZE);
+    assert!((CODE_START + code.len()) < MAP_SIZE);
 
     // The idiomatic way is to write a wrapper struct for `mmap`-ing regions
     // and exposing it as a slice (std::slice::from_raw_parts)
     // But we just copy the code directly here
     unsafe {
-        std::ptr::copy_nonoverlapping(code.as_ptr(), *mapping as *mut _, code.len());
+        std::ptr::copy_nonoverlapping(code.as_ptr(), (*mapping as *mut u8).add(CODE_START), code.len());
     };
 
-    let mut sregs = kvm.get_vcpu_sregs()?;
+    let mapped_slice = unsafe { slice::from_raw_parts_mut(*mapping as _, MAP_SIZE) };
 
-    // CS points to the reset vector by default
-    sregs.cs.base = 0;
-    sregs.cs.selector = 0;
+    util::setup_gdt(mapped_slice);
+    util::setup_paging(mapped_slice);
+
+    // Ignore boot_params for now
+    kvm.set_vcpu_regs(&util::setup_regs(CODE_START as u64, 0))?;
+    kvm.set_vcpu_sregs(&util::setup_sregs())?;
 
-    kvm.set_vcpu_sregs(&sregs)?;
     kvm.set_user_memory_region(0, MAP_SIZE, *mapping as u64)?;
-    kvm.set_vcpu_regs(&kvm_regs {
-        // The first bit must be set on x86
-        rflags: 1 << 1,
-        // The instruction pointer is set to 0 as our code is loaded with 0
-        // as the base address
-        rip: 0,
-        ..Default::default()
-    })?;
 
     loop {
         let kvm_run = kvm.run()?;
```

The final code for this section can be found [here](https://github.com/git-bruh/site/tree/master/code/kvm/long-mode)

# Sanity Check

Before we go ahead with loading the kernel image, let's write a small hello world program as before, but 64-bit rather than 16-bit, `hello.S`:

```asm
BITS 64

; Output to port 0x3f8
mov dx, 0x3f8

; 0x4000 is added to the message address as that's where our code is loaded
mov rbx, message + 0x4000

loop:
    ; Load a byte from `bx` into the `al` register
    mov al, [rbx]

    ; Jump to the `hlt` instruction if we encountered the NUL terminator
    cmp al, 0
    je end

    ; Output to the serial port
    out dx, al
    ; Increment `rbx` by one byte to point to the next character
    inc rbx

    jmp loop

end:
    hlt

message:
    db "Hello, KVM!", 0
```

After building with `nasm hello.S`:

```rs
$ nasm hello.S && cargo run hello
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

# Loading the Kernel Image

Now, we can actually get to the main topic! We don't need to do much now, just implement what the boot protocol asks for, and setup a few more things with KVM APIs

First off, we need to load the [setup header](https://github.com/torvalds/linux/blob/7367539ad4b0f8f9b396baf02110962333719a48/arch/x86/include/uapi/asm/bootparam.h#L38) from our kernel image which is used to provide details like the addresses of the kernel command line and initramfs, among other metadata. It is generated at build time and is embedded at the beginning of the kernel image. The main fields we need to modify are:

- `ramdisk_image`, `ramdisk_size`: The address and size of the initramfs to be loaded

- `cmd_line_ptr`: The address of the NUL-terminated kernel command line. The `ext_cmd_line_ptr` field is explicitly zeroed as it seems to be set to a garbage value as a side-effect of commit [d9b6b6](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/commit/?h=v6.6.18&id=d9b6b6e8d871b6ca8d3c8f0d2bb7f327edaf7a2e), breaking calculations in [`get_cmd_line_ptr()`](https://github.com/torvalds/linux/blob/f462ae0edd3703edd6f22fe41d336369c38b884b/arch/x86/boot/compressed/cmdline.c#L21) which caused a long drawn out debugging session :p

- `e820_table`: E820 entries tell the kernel about the reserved and available memory regions. We make the memory starting from the kernel's start address till the end of our mapped memory usable, and mark a small section in the beginning as reserved for a 1KB EBDA (Extended BIOS Data Area) region. We don't interact with it directly but the kernel can misbehave without the area being marked as reserved:

```rs
[
    // Memory before the EBDA entry
    boot_e820_entry {
        addr: 0,
        size: 0x9fc00,
        // E820_RAM
        type_: 1,
    },
    // Reserved EBDA entry
    boot_e820_entry {
        addr: 0x9fc00,
        size: 1 << 10,
        // E820_RESERVED,
        type_: 2,
    },
    // Memory after the beginning of the kernel image
    boot_e820_entry {
        addr: 0x100000,
        size: MAPPING_SIZE as u64 - 0x100000,
        type_: 1,
    },
]
```

```rs
pub fn new(
    bz_image: &'a [u8],
    cmdline_addr: u32,
    initramfs_addr: Option<u32>,
    initramfs_size: Option<u32>,
    e820_entries: &[boot_e820_entry],
) -> Result<BzImage<'a>, LoaderError> {
    // The setup_header is located at offset 0x1f1 (`hdr` field) from the start
    // of `boot_params` (which is also the start of the kernel image)
    let mut boot_params = boot_params::default();

    // Ref: 1.3. Details of Header Fields
    // We just need to modify a few fields here to tell the kernel about
    // the environment we're setting up. Rest of the information is already
    // filled in the struct (embedded in the bz_image)

    if bz_image.len() < mem::size_of_val(&boot_params) {
        return Err(LoaderError::ImageTooSmall);
    }

    unsafe {
        ptr::copy_nonoverlapping(bz_image.as_ptr().cast(), &mut boot_params, 1);
    }

    // `boot_flag` and `header` are magic values documented in the boot protocol
    // > Then, the setup header at offset 0x01f1 of kernel image on should be
    // > loaded into struct boot_params and examined. The end of setup header
    // > can be calculated as follows: 0x0202 + byte value at offset 0x0201
    // 0x0201 refers to the 16 bit `jump` field of the `setup_header` struct
    // Contains an x86 jump instruction, 0xEB followed by a signed offset relative to byte 0x202
    // So we just read a byte out of it, i.e. the offset from the header (0x0202)
    // It should always be 106 unless a field after `kernel_info_offset` is added
    if boot_params.hdr.boot_flag != 0xAA55
        || boot_params.hdr.header != 0x53726448
        || (boot_params.hdr.jump >> 8) != 106
    {
        return Err(LoaderError::InvalidImage);
    }

    if bz_image.len() < kernel_byte_offset(&boot_params) {
        return Err(LoaderError::ImageTooSmall);
    }

    // VGA display
    boot_params.hdr.vid_mode = 0xFFFF;

    // "Undefined" Bootloader ID
    boot_params.hdr.type_of_loader = 0xFF;

    // LOADED_HIGH: the protected-mode code is loaded at 0x100000
    // CAN_USE_HEAP: Self explanatory
    boot_params.hdr.loadflags |= (LOADED_HIGH | CAN_USE_HEAP) as u8;

    boot_params.hdr.ramdisk_image = initramfs_addr.unwrap_or(0);
    boot_params.hdr.ramdisk_size = initramfs_size.unwrap_or(0);

    // https://www.kernel.org/doc/html/latest/arch/x86/boot.html#sample-boot-configuration
    // 0xe000 - 0x200
    boot_params.hdr.heap_end_ptr = 0xde00;
    // The command line parameters can be located anywhere in 64-bit mode
    // Must be NUL terminated
    boot_params.hdr.cmd_line_ptr = cmdline_addr;
    boot_params.ext_cmd_line_ptr = 0;

    boot_params.e820_entries = e820_entries
        .len()
        .try_into()
        .map_err(|_| LoaderError::TooManyEntries)?;
    boot_params.e820_table[..e820_entries.len()].copy_from_slice(e820_entries);

    Ok(Self {
        bz_image,
        boot_params,
    })
}
```

Now, we just need to place everything at the respective physical addresses:

```rs
const MAPPING_SIZE: usize = 1 << 30;

const CMDLINE: &[u8] = b"console=ttyS0 earlyprintk=ttyS0 rdinit=/init\0";

const ADDR_BOOT_PARAMS: usize = 0x10000;
const ADDR_CMDLINE: usize = 0x20000;
const ADDR_KERNEL32: usize = 0x100000;
const ADDR_INITRAMFS: usize = 0xf000000;
```

The boot parameters, initramfs and kernel cmdline can be located at arbritary addresses as we explicitly pass their address. Only the kernel has to be loaded at a fixed address. The initramfs is loaded at a higher address as we don't want the kernel image to overflow into the initramfs, causing corruption

We need to setup a few more fundamental components now:

- IRQCHIP, PIT2: They emulate the required machinery for handling interrupts inside the guest

- CPUID: Setting the CPUID features influences the behaviour of the `cpuid` instruction inside the VM. `kvm_get_supported_cpuid` gets us the feature set of the host CPU, which we expose to the guest

- Identity Map, TSS (Task State Segment): Intel-specific quirks, these pages can be located anywhere in the first 4GB of guest memory. We opt to store the Identity Map at `0xFFFFC000` and TSS at `0xFFFFD000` (one page after the Identity Map), same as most other projects

```diff
@@ -42,15 +42,24 @@ impl Kvm {
         let kvm =
             unsafe { OwnedFd::from_raw_fd(fcntl::open("/dev/kvm", OFlag::O_RDWR, Mode::empty())?) };
         let vm = unsafe { OwnedFd::from_raw_fd(kvm_create_vm(kvm.as_raw_fd(), 0)?) };
+
+        // TODO refactor this, it should be done outside `new`
+        unsafe {
+            kvm_create_irqchip(vm.as_raw_fd())?;
+            kvm_create_pit2(vm.as_raw_fd(), &kvm_pit_config::default())?;
+
+            let idmap_addr = 0xFFFFC000;
+            kvm_set_identity_map_addr(vm.as_raw_fd(), &idmap_addr)?;
+        };
+
         let vcpu = unsafe { OwnedFd::from_raw_fd(kvm_create_vcpu(vm.as_raw_fd(), 0)?) };
@@ -124,6 +133,23 @@ impl Kvm {
         Ok(())
     }
 
+    pub fn set_tss_addr(&self, addr: u64) -> Result<(), std::io::Error> {
+        unsafe { kvm_set_tss_addr(self.vm.as_raw_fd(), addr)? };
+
+        Ok(())
+    }
+
+    pub fn setup_cpuid(&self) -> Result<(), std::io::Error> {
+        let mut cpuid2 = CpuId::new(80).expect("should not fail to construct CpuId!");
+
+        unsafe {
+            kvm_get_supported_cpuid(self.kvm.as_raw_fd(), cpuid2.as_mut_fam_struct_ptr())?;
+            kvm_set_cpuid2(self.vcpu.as_raw_fd(), cpuid2.as_fam_struct_ptr())?;
+        };
+
+        Ok(())
+    }
+
     pub fn run(&self) -> Result<*const kvm_run, std::io::Error> {
```

That's it! Now, putting all these APIs together:

```rs
const CMDLINE: &[u8] = b"console=ttyS0 earlyprintk=ttyS0 rdinit=/init\0";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let kvm = Kvm::new()?;
    let mut bz_image = Vec::new();

    File::open(env::args().nth(1).expect("no bzImage passed!"))
        .expect("failed to open bzImage!")
        .read_to_end(&mut bz_image)
        .expect("failed to read!");

    let mut initramfs = Vec::new();

    File::open(env::args().nth(2).expect("no initramfs passed!"))
        .expect("failed to open initramfs")
        .read_to_end(&mut initramfs)
        .expect("failed to read!");

    let loader = BzImage::new(
        &bz_image,
        ADDR_CMDLINE.try_into().expect("cmdline address too large!"),
        Some(
            ADDR_INITRAMFS
                .try_into()
                .expect("initramfs address too large!"),
        ),
        Some(initramfs.len().try_into().expect("initramfs too big")),
        &[
            ...
            // Memory after the beginning of the kernel image
            boot_e820_entry {
                addr: 0x100000,
                size: MAPPING_SIZE as u64 - 0x100000,
                type_: 1,
            },
        ],
    )
    .expect("failed to construct loader!");

    // Create a mapping for the "user" memory region where we'll copy the
    // startup code into
    let wrapped_mapping = WrappedAutoFree::new(...);

    let mapped_slice = unsafe { slice::from_raw_parts_mut(*wrapped_mapping as _, MAPPING_SIZE) };

    unsafe {
        ...
        let kernel32 = loader.kernel32_slice();
        std::ptr::copy_nonoverlapping(
            kernel32.as_ptr(),
            wrapped_mapping.add(ADDR_KERNEL32) as *mut _,
            kernel32.len(),
        );
        ...
    }

    util::setup_gdt(mapped_slice);
    util::setup_paging(mapped_slice);

    kvm.set_user_memory_region(0x0, MAPPING_SIZE as u64, *wrapped_mapping as u64)?;
    kvm.set_vcpu_regs(&util::setup_regs(
        // 64-bit code is located 512 bytes ahead of the 32-bit code
        ADDR_KERNEL32 as u64 + 0x200,
        // boot params are stored in rsi
        ADDR_BOOT_PARAMS as u64,
    ))?;
    kvm.set_vcpu_sregs(&util::setup_sregs())?;
    kvm.set_tss_addr(0xFFFFD000)?;
    kvm.setup_cpuid()?;

    let mut buffer = String::new();

    loop {
        let kvm_run = kvm.run()?;

        unsafe {
            match (*kvm_run).exit_reason {
                KVM_EXIT_HLT => {
                    eprintln!("KVM_EXIT_HLT");
                    break;
                }
                KVM_EXIT_IO => {
                    let port = (*kvm_run).__bindgen_anon_1.io.port;
                    let byte = *((kvm_run as u64 + (*kvm_run).__bindgen_anon_1.io.data_offset)
                        as *const u8);

                    if port == 0x3f8 {
                        match byte {
                            b'\r' | b'\n' => {
                                println!("{buffer}");
                                buffer.clear();
                            }
                            c => {
                                buffer.push(c as char);
                            }
                        }
                    }

                    eprintln!("IO for port {port}: {byte:#X}");

                    // `in` instruction, tell it that we're ready to receive data (XMTRDY)
                    // arch/x86/boot/tty.c
                    if (*kvm_run).__bindgen_anon_1.io.direction == 0 {
                        *((kvm_run as *mut u8)
                            .add((*kvm_run).__bindgen_anon_1.io.data_offset as usize)) = 0x20;
                    }
                }
                reason => {
                    eprintln!("Unhandled exit reason: {reason}");
                    break;
                }
            }
        }
    }

    Ok(())
}
```

# Building a Kernel

We'll build a tiny kernel for testing our hypervisor, starting with `make tinyconfig`, and enabling these options to make it usable (options should be self explanatory):

```
General setup  --->
    [*] Initial RAM filesystem and RAM disk (initramfs/initrd) support
    [*] Configure standard kernel features (expert users)  --->
        [*]   Enable support for printk
[*] 64-bit kernel
Executable file formats  --->
    [*] Kernel support for ELF binaries
Device Drivers  --->
    Generic Driver Options  --->
        [*] Maintain a devtmpfs filesystem to mount at /dev
Kernel hacking  --->
    printk and dmesg options  --->
        [*] Show timing information on printks
    x86 Debugging  --->
        [*] Enable verbose x86 bootup info messages
        [*] Early printk
```

Note that the kernel command line we pass is `console=ttyS0 earlyprintk=ttyS0 rdinit=/init`, and our code prints out data printed on port `0x3f8`, which is equivalent to `ttyS0`

Now, running this kernel as it is would just panic as there's no init found:

```sh
# First argument is the kernel image and 2nd is the initramfs
# We don't have an initramfs so we pass /dev/null
# stderr is redirected as we don't want verbose output about IO ports
$ cargo run /tmp/linux-6.8.6/arch/x86/boot/bzImage /dev/null 2>/dev/null
early console in extract_kernel
input_data: 0x00000000018b8298
input_len: 0x00000000000a87c0
output: 0x0000000001000000
output_len: 0x0000000000936900
kernel_total_size: 0x0000000000818000
needed_size: 0x0000000000a00000
trampoline_32bit: 0x0000000000000000
Decompressing Linux... Parsing ELF... done.
Booting the kernel (entry_offset: 0x0000000000000000).
[    0.000000] Linux version 6.8.6 (testuser@shed) (gcc (GCC) 13.2.0, GNU ld (GNU Binutils) 2.42) #5 Mon May  6 00:10:00 IST 2024
[    0.000000] Command line: console=ttyS0 earlyprintk=ttyS0 rdinit=/init
...
[    0.055361] Run /bin/sh as init process
[    0.055659] Kernel panic - not syncing: No working init found.  Try passing init= option to kernel. See Linux Documentation/admin-guide/init.rst for guidance.
[    0.056588] Kernel Offset: disabled
[    0.056813] ---[ end Kernel panic - not syncing: No working init found.  Try passing init= option to kernel. See Linux Documentation/admin-guide/init.rst for guidance. ]---
```

For now, we can just provide a dummy init program that does an arbitary task, like printing out the contents of `/dev`:

```c
// Bounds checks omitted
int main(void) {
  char msg[4096] = "Hello from userspace!";
  size_t idx = 0;

  if (mount("dev", "/dev", "devtmpfs", 0, NULL) == -1) {
    return EXIT_FAILURE;
  }

  int kmsg = open("/dev/kmsg", O_WRONLY | O_APPEND);
  if (kmsg == -1) {
    return EXIT_FAILURE;
  }

  DIR *dir = opendir("/dev");
  if (!dir) {
    return EXIT_FAILURE;
  }

  // Write the original message once before overwriting it
  if (write(kmsg, msg, strlen(msg)) == -1) {
    return EXIT_FAILURE;
  }

  for (struct dirent *dp = NULL; (dp = readdir(dir)) != NULL;) {
    for (char *name = dp->d_name; *name != '\0'; name++) {
      msg[idx++] = *name;
    }

    msg[idx++] = ' ';
  }

  msg[idx++] = '\0';

  if (write(kmsg, msg, idx) == -1) {
    return EXIT_FAILURE;
  }

  closedir(dir);
  close(kmsg);
}
```

We mount a `devtmpfs` filesystem at `/dev` to access `/dev/kmsg`, which is the kernel buffer. We write to it directly as a hack, as we don't emulate a full-fledged serial console yet, so whatever we'd print to `stdout` would not make it's way to us :p

As for getting this executed, we don't have any mechanism to share the filesystem directly for now, so we will just wrap this up in a dummy initramfs, bypassing the need for a filesystem altogether. We did something similar in [this](/2023-07-07.html) post about init systems:

```sh
# Must be a static binary as we don't have a proper rootfs setup
$ cc contrib/init.c -o init -static
# cpio takes the file list from stdin
$ echo init | cpio -o -H newc > initramfs
$ cargo run /tmp/linux-6.8.6/arch/x86/boot/bzImage initramfs 2>/dev/null
...

[    0.049393] Run /init as init process
[    0.049715] Hello from userspace!
[    0.049718] . .. kmsg urandom random full zero null 
[    0.049934] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
[    0.050717] Kernel Offset: disabled
[    0.050935] ---[ end Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000 ]---
```

It now prints the desired output, but we still get a panic as the `init` process exits, which is expected. Note that even though we used this tiny kernel here, even a larger distro kernel would boot just fine (you can try it!)

# Conclusion

The final code for this post can be found [here](https://github.com/git-bruh/vmm/blob/dbe796b8543339f86b2a66913546c61235f12550/README.md)

We've got our hypervisor to boot into userspace, but it's still quite limited in functionality. We'll be covering VirtIO devices next so we can provide a serial console, and also cleaning up the un-rusty code full of raw pointers and `as T` spam :p

There was also quite a bit of debugging involved that was not covered here, which would probably need it's own dedicated post. But more or less you're on your own here without a debugger. There's an [`enable_debug()`](https://github.com/git-bruh/vmm/blob/dbe796b8543339f86b2a66913546c61235f12550/src/kvm.rs#L161) function which enables single-step debugging, allowing instruction-by-instruction tracing, which can then be used to print out the state of registers at each level. Then, the instruction pointer can be correlated with the disassembly of the kernel image, adjusted for the offset calculated in [`kernel_byte_offset()`](https://github.com/git-bruh/vmm/blob/dbe796b8543339f86b2a66913546c61235f12550/src/linux_loader.rs#L60). The 64-bit code starts here in [arch/x86/boot/compressed/head_64.S](https://github.com/torvalds/linux/blob/f462ae0edd3703edd6f22fe41d336369c38b884b/arch/x86/boot/compressed/head_64.S#L286), inserting `asm("hlt")` statements here and there might help binary search the code being executed

# Further Reading 

- Reference Projects

  - [firecracker](https://github.com/firecracker-microvm/firecracker)

  - [gokvm](https://github.com/bobuhiro11/gokvm)

  - [kvmtool](https://github.com/kvmtool/kvmtool)

- [The Linux/x86 Boot Protocol](https://www.kernel.org/doc/html/latest/arch/x86/boot.html)

- [Kernel booting process](https://0xax.gitbooks.io/linux-insides/content/Booting/linux-bootstrap-1.html)

- [Introduction to Paging](https://os.phil-opp.com/paging-introduction)

- [Understanding x86_64 Paging](https://zolutal.github.io/understanding-paging)

- [Physical Address Extension, OSDev](https://wiki.osdev.org/PAE)

- [Paging, OSDev](https://wiki.osdev.org/Paging)

- [Identity Paging, OSDev](https://wiki.osdev.org/Identity_Paging)

- [GDT Tutorial, OSDev](https://wiki.osdev.org/GDT_Tutorial)

- [Setting Up Long Mode, OSDev](https://wiki.osdev.org/Setting_Up_Long_Mode)

- [Intel SDM](https://cdrdv2.intel.com/v1/dl/getContent/671447)

use crate::constants::{Cr0Flags, Cr4Flags, EferFlags, PageFlags, PageTables, SegmentFlags};
use kvm_bindings::{kvm_dtable, kvm_regs, kvm_segment, kvm_sregs};
use std::mem;

/// CS, placed at 0x10
/// See `pack_segment` for more details
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
/// See `pack_segment` for more details
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

/// Packs a `kvm_segment` into a 64-bit value
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

/// Sets up the GDT according to the boot protocol
pub fn setup_gdt(memory: &mut [u64]) {
    // CS (0x10)
    memory[2] = pack_segment(&CODE_SEGMENT);
    // DS (0x18)
    memory[3] = pack_segment(&DATA_SEGMENT);
}

/// Sets up paging with identity mapping
pub fn setup_paging(memory: &mut [u64]) {
    let entry_size = mem::size_of::<u64>();

    memory[PageTables::PML4 / entry_size] =
        PageFlags::PRESENT | PageFlags::READ_WRITE | PageTables::PDPT as u64;
    memory[PageTables::PDPT / entry_size] =
        PageFlags::PRESENT | PageFlags::READ_WRITE | PageTables::PD as u64;

    let pd = &mut memory[(PageTables::PD / entry_size)..][..512];

    // Identity Mapping
    for (n, entry) in pd.iter_mut().enumerate() {
        *entry =
            PageFlags::PRESENT | PageFlags::READ_WRITE | PageFlags::PAGE_SIZE | ((n as u64) << 21);
    }
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

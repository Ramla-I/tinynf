use std::cell::RefCell;
use std::convert::TryInto;
use std::fs::OpenOptions;
use std::io::{self, Read, Seek};
use std::mem::size_of;
use std::ptr;
use std::slice;
use std::thread;
use std::time::Duration;

use x86_64::instructions::port::Port;

use crate::pci::PciAddress;

// TODO might be worth splitting this file into a proper module

pub trait Environment<'a> {
    fn allocate<T, const COUNT: usize>(&self) -> &'a mut [T; COUNT];
    fn allocate_slice<T>(&self, count: usize) -> &'a mut [T];
    fn map_physical_memory<T>(&self, addr: u64, count: usize) -> &'static mut [T]; // addr is u64, not usize, because PCI BARs are 64-bit
    fn get_physical_address<T>(&self, value: *mut T) -> usize; // mut to emphasize that gaining the phys addr might allow HW to write

    fn pci_read(&self, addr: PciAddress, register: u8) -> u32;
    fn pci_write(&self, addr: PciAddress, register: u8, value: u32);

    fn sleep(&self, duration: Duration);
}

// --- PCI ---

const PCI_CONFIG_ADDR: u16 = 0xCF8;
const PCI_CONFIG_DATA: u16 = 0xCFC;

fn port_out_32(port: u16, value: u32) {
    unsafe {
        if libc::ioperm(port.into(), 4, 1) < 0 || libc::ioperm(0x80, 1, 1) < 0 {
            panic!("Could not ioperm, are you root?");
        }
        Port::new(port).write(value);
        Port::new(0x80).write(0u8);
    }
}

fn port_in_32(port: u16) -> u32 {
    unsafe {
        if libc::ioperm(port.into(), 4, 1) < 0 {
            panic!("Could not ioperm, are you root?");
        }
        Port::new(port).read()
    }
}

fn pci_target(address: PciAddress, register: u8) {
    port_out_32(
        PCI_CONFIG_ADDR,
        0x80000000 | ((address.bus as u32) << 16) | ((address.device as u32) << 11) | ((address.function as u32) << 8) | register as u32,
    );
}

// --- Linux ---

const HUGEPAGE_LOG: usize = 30; // 1 GB hugepages
const HUGEPAGE_SIZE: usize = 1 << HUGEPAGE_LOG;

// this is terrible and should be fixed but oh well
static mut MAPS: Vec<memmap::MmapMut> = Vec::new();

pub struct LinuxEnvironment {
    allocated_page: RefCell<*mut u8>,
    used_bytes: RefCell<usize>
}

impl LinuxEnvironment {
    pub fn new() -> LinuxEnvironment {
        unsafe {
            let page = libc::mmap(
                ptr::null_mut(),
                HUGEPAGE_SIZE,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_HUGETLB | (HUGEPAGE_LOG << libc::MAP_HUGE_SHIFT) as i32 | libc::MAP_ANONYMOUS | libc::MAP_SHARED | libc::MAP_POPULATE,
                -1,
                0,
            );
            if page == libc::MAP_FAILED {
                panic!("Mmap failed");
            }

            LinuxEnvironment {
                allocated_page: RefCell::new(page as *mut u8),
                used_bytes: RefCell::new(0),
            }
        }
    }
}

impl<'a> Environment<'a> for LinuxEnvironment {
    fn allocate<T, const COUNT: usize>(&self) -> &'a mut [T; COUNT] {
        self.allocate_slice(COUNT).try_into().unwrap()
    }

    fn allocate_slice<T>(&self, count: usize) -> &'a mut [T] {
        let mut allocated_page = self.allocated_page.borrow_mut();
        let mut used_bytes = self.used_bytes.borrow_mut();
        let align_diff = *used_bytes % (size_of::<T>() + 64 - (size_of::<T>() % 64));
        if align_diff + *used_bytes >= HUGEPAGE_SIZE {
            panic!("Not enough space for alignment");
        }

        unsafe {
            *allocated_page = (*allocated_page).add(align_diff);
        }
        *used_bytes += align_diff;

        let full_size = count * size_of::<T>();
        if full_size + *used_bytes >= HUGEPAGE_SIZE {
            panic!("Not enough space for allocation");
        }

        let result = *allocated_page;
        unsafe {
            *allocated_page = (*allocated_page).add(full_size);
        }
        *used_bytes += full_size;

        unsafe { slice::from_raw_parts_mut(result as *mut T, count) }
    }

    fn map_physical_memory<T>(&self, addr: u64, count: usize) -> &'static mut [T] {
        let full_size = count * size_of::<T>();
        let file = OpenOptions::new().read(true).write(true).open("/dev/mem").unwrap();
        unsafe {
            let map = memmap::MmapOptions::new().offset(addr).len(full_size).map_mut(&file).unwrap();
            MAPS.push(map);
            let result = &mut MAPS[MAPS.len() - 1][..];
            let (prefix, result, suffix) = result.align_to_mut::<T>();
            if !prefix.is_empty() || !suffix.is_empty() {
                panic!("Something went wrong with the /dev/mem mapping");
            }
            result
        }
    }

    fn get_physical_address<T>(&self, value: *mut T) -> usize {
        unsafe {
            let page_size = libc::sysconf(libc::_SC_PAGE_SIZE) as usize;
            let addr = value as usize;
            let page = addr / page_size;
            let map_offset = page * size_of::<u64>();

            let mut pagemap = OpenOptions::new().read(true).open("/proc/self/pagemap").unwrap();
            pagemap.seek(io::SeekFrom::Start(map_offset as u64)).unwrap();

            let mut buffer = [0; size_of::<u64>()];
            pagemap.read_exact(&mut buffer).unwrap();

            let metadata = u64::from_ne_bytes(buffer);
            if (metadata & 0x8000_0000_0000_0000) == 0 {
                panic!("Page not present");
            }

            let pfn = metadata & 0x7F_FFFF_FFFF_FFFF;
            if pfn == 0 {
                panic!("Page not mapped");
            }

            let addr_offset = addr % page_size;
            pfn as usize * page_size + addr_offset
        }
    }

    fn pci_read(&self, addr: PciAddress, register: u8) -> u32 {
        pci_target(addr, register);
        port_in_32(PCI_CONFIG_DATA)
    }

    fn pci_write(&self, addr: PciAddress, register: u8, value: u32) {
        pci_target(addr, register);
        port_out_32(PCI_CONFIG_DATA, value);
    }

    fn sleep(&self, duration: Duration) {
        thread::sleep(duration);
    }
}

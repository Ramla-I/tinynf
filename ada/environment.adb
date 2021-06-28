with Ada.Unchecked_Conversion;
with System; use System;
with System.Address_to_Access_Conversions;
with System.Machine_Code;
with System.Storage_Elements; use System.Storage_Elements;
with Interfaces; use Interfaces;
with Interfaces.C;
with GNAT.OS_Lib; use GNAT.OS_Lib;

package body Environment is
  -- void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset);
  function Mmap(addr: Address;
                length: Interfaces.C.size_t;
                prot: Interfaces.C.int;
                flags: Interfaces.C.int;
                fd: Interfaces.C.int;
                offset: Interfaces.C.long) return Address
    with Import => True,
         Convention => C,
         External_Name => "mmap";

  Huge_Page_Size: constant := 2 ** 30; -- 1 GB

  type Flags is mod Interfaces.C.int'Last;
  PROT_READ: constant Flags := 1;
  PROT_WRITE: constant Flags := 2;
  MAP_SHARED: constant Flags := 16#1#;
  MAP_ANONYMOUS: constant Flags := 16#20#;
  MAP_POPULATE: constant Flags := 16#8000#;
  MAP_HUGETLB: constant Flags := 16#40000#;
  MAP_HUGE_1GB: constant Flags := 16#78000000#; -- Huge_Page_Size << 26

  Allocator_Page: Address := Mmap(Null_Address,
                                  Huge_Page_Size,
                                  Interfaces.C.int(PROT_READ or PROT_WRITE),
                                  Interfaces.C.int(MAP_HUGETLB or MAP_HUGE_1GB or MAP_ANONYMOUS or MAP_SHARED or MAP_POPULATE),
                                  Interfaces.C.int(-1),
                                  Interfaces.C.long(0));
  Allocator_Used_Bytes: Storage_Offset := 0;

  function Allocate(Count: in Integer) return T_Array is
    Align_Diff: Storage_Offset;
  begin
    if Allocator_Page = To_Address(-1) then -- MAP_FAILED
      OS_Exit(1);
    end if;

    -- Note that Ada's 'Size is in bits!

    Align_Diff := Allocator_Used_Bytes rem (T'Size/8 + 64 - (T'Size/8 rem 64));
    Allocator_Page := Allocator_Page + Align_Diff;
    Allocator_Used_Bytes := Allocator_Used_Bytes + Align_Diff;

    declare
      Result: T_Array(0.. Count - 1);
      for Result'Address use Allocator_Page;
    begin
      Allocator_Page := Allocator_Page + Storage_Offset(Count * T'Size/8);
      Allocator_Used_Bytes := Allocator_Used_bytes + Storage_Offset(Count * T'Size/8);
      return Result;
    end;
  end;


  -- long sysconf(int name);
  function Sysconf(Name: Interfaces.C.int) return Interfaces.C.long
    with Import => True,
         Convention => C,
         External_Name => "sysconf";

  SC_PAGESIZE: constant Interfaces.C.int := 30;

  function Get_Physical_Address(Value: T_Access) return Interfaces.Unsigned_64 is
    package T_Conversions is new System.Address_to_Access_Conversions(T);
    Page_Size: Integer_Address;
    Addr: Integer_Address;
    Page: Integer_Address;
    Page_Map_FD: File_Descriptor;
    Metadata: Interfaces.Unsigned_64;
    Read_Count: Integer;
    PFN: Interfaces.Unsigned_64;
  begin
    Page_Size := Integer_Address(Sysconf(SC_PAGESIZE));
    if Page_Size < 0 then
      OS_Exit(2);
    end if;

    Addr := To_Integer(T_Conversions.To_Address(T_Conversions.Object_Pointer(Value)));
    Page := Addr / Page_Size;

    Page_Map_FD := Open_Read("/proc/self/pagemap", Binary);
    if Page_Map_FD < 0 then
      OS_Exit(3);
    end if;

    LSeek(Page_Map_FD, Long_Integer(Page) / 64, Seek_Cur);
    Read_Count := Read(Page_Map_FD, Metadata'Address, Metadata'Size/8);
    if Read_Count < Metadata'Size/8 then
      OS_Exit(4);
    end if;

    if (Metadata and 16#8000000000000000#) = 0 then
      OS_Exit(5);
    end if;

    PFN := Metadata and 16#7FFFFFFFFFFFFF#;
    if PFN = 0 then
      OS_Exit(6);
    end if;

    return PFN * Interfaces.Unsigned_64(Page_Size) + Interfaces.Unsigned_64(Addr rem Page_Size);
  end;


  function Map_Physical_Memory(Addr: Integer; Count: Integer) return T_Array is
    Mem_FD: File_Descriptor;
    Mapped_Address: Address;
  begin
    Mem_FD := Open_Read_Write("/dev/mem", Binary);
    if Mem_FD < 0 then
      OS_Exit(7);
    end if;

    Mapped_Address := Mmap(Null_Address,
                           Interfaces.C.size_t(Count * T'Size/8),
                           Interfaces.C.int(PROT_READ or PROT_WRITE),
                           Interfaces.C.int(MAP_SHARED),
                           Interfaces.C.int(Mem_FD),
                           Interfaces.C.long(Addr));
    if Mapped_Address = To_Address(-1) then
      OS_Exit(8);
    end if;

    Close(Mem_FD);

    declare
      Result: T_Array(0 .. Count - 1);
      for Result'Address use Mapped_Address;
    begin
      return Result;
    end;
  end;



  -- int ioperm(unsigned long from, unsigned long num, int turn_on);
  function IOPerm(From: Interfaces.C.unsigned_long; Num: Interfaces.C.unsigned_long; Turn_On: Interfaces.C.int) return Interfaces.C.int
    with Import => True,
         Convention => C,
         External_Name => "ioperm";

  PCI_CONFIG_ADDR: constant := 16#CF8#;
  PCI_CONFIG_DATA: constant := 16#CFC#;

  procedure IO_outl(Port: in Interfaces.Unsigned_16; Value: in Interfaces.Unsigned_32) is
  begin
    System.Machine_Code.Asm("outl %0, %w1", Inputs => (Interfaces.Unsigned_32'Asm_Input("a", Value), Interfaces.Unsigned_16'Asm_Input("Nd", Port)), Volatile => True);
  end;

  procedure IO_outb(Port: in Interfaces.Unsigned_16; Value: in Interfaces.Unsigned_8) is
  begin
    System.Machine_Code.Asm("outb %b0, %w1", Inputs => (Interfaces.Unsigned_8'Asm_Input("a", Value), Interfaces.Unsigned_16'Asm_Input("Nd", Port)), Volatile => True);
  end;

  function IO_inl(Port: in Interfaces.Unsigned_16) return Interfaces.Unsigned_32 is
    Value: Interfaces.Unsigned_32;
  begin
    System.Machine_Code.Asm("inl %w1, %0", Outputs => Interfaces.Unsigned_32'Asm_Output("=a", Value), Inputs => Interfaces.Unsigned_16'Asm_Input("Nd", Port), Volatile => True);
    return Value;
  end;

  procedure Pci_Target(Addr: in Pci_Address; Reg: in Pci_Register) is
  begin
    IO_outl(PCI_CONFIG_ADDR,
            16#80000000# or
            Shift_Left(Interfaces.Unsigned_32(Addr.Bus), 16) or
            Shift_Left(Interfaces.Unsigned_32(Addr.Device), 11) or
            Shift_Left(Interfaces.Unsigned_32(Addr.Func), 8) or
            Interfaces.Unsigned_32(Reg));
    IO_outb(16#80#, 0);
  end;

  procedure IO_Ensure_Access is
  begin
    if Integer(IOPerm(16#80#, 1, 1)) < 0 or else Integer(IOPerm(PCI_CONFIG_ADDR, 4, 1)) < 0 or else Integer(IOPerm(PCI_CONFIG_DATA, 4, 1)) < 0 then
      OS_Exit(10);
    end if;
  end;

  function Pci_Read(Addr: in Pci_Address; Reg: in Pci_Register) return Pci_Value is
  begin
    IO_Ensure_Access;
    Pci_Target(Addr, Reg);
    return Pci_Value(IO_inl(PCI_CONFIG_DATA));
  end;

  procedure Pci_Write(Addr: in Pci_Address; Reg: in Pci_Register; Value: in Pci_Value) is
  begin
    IO_Ensure_Access;
    Pci_Target(Addr, Reg);
    IO_outl(PCI_CONFIG_DATA, Interfaces.Unsigned_32(Value));
  end;
end Environment;

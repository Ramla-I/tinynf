with Interfaces;

with Ixgbe_Constants;

package Ixgbe is
  type VolatileUInt32 is mod 2 ** 32
    with Volatile;
  type VolatileUInt64 is mod 2 ** 64
    with Volatile;

  -- little-endian only for now
  function From_Little(Value: in VolatileUInt32) return VolatileUInt32 is (Value);
  function From_Little(Value: in VolatileUInt64) return VolatileUInt64 is (Value);
  function To_Little(Value: in VolatileUInt32) return VolatileUInt32 is (Value);
  function To_Little(Value: in VolatileUInt64) return VolatileUInt64 is (Value);

  type Descriptor is record
    Buffer: VolatileUInt64;
    Metadata: VolatileUInt64;
  end record
    with Pack;

  type Transmit_Head is record
    Value: VolatileUInt32;
  end record;
  for Transmit_Head'Alignment use 64; -- full cache line to avoid contention

  type Delimiter_Range is mod Ixgbe_Constants.Ring_Size;
  type Descriptor_Ring is array(Delimiter_Range) of aliased Descriptor;

  type Dev_Buffer_Range is new Integer range 0 .. 128 * 1024 / 4 - 1;
  type Dev_Buffer is array(Dev_Buffer_Range) of aliased VolatileUInt32;
  type Dev_Buffer_Access is access all Dev_Buffer;
end Ixgbe;

﻿using System;
using System.Runtime.CompilerServices;

namespace TinyNF.Unsafe
{
    /// <summary>
    /// Packet data.
    /// This struct is entirely safe, C# just cannot define it without unsafe yet.
    /// See https://github.com/dotnet/csharplang/blob/main/proposals/fixed-sized-buffers.md
    /// and https://github.com/dotnet/csharplang/issues/1314
    /// </summary>
    public unsafe struct PacketData
    {
        public const int Size = 2048;

        private fixed byte _data[Size];

        public ref byte this[uint index]
        {
            get
            {
                if (index >= Size)
                {
                    throw new ArgumentOutOfRangeException(nameof(index));
                }
                return ref _data[index];
            }
        }

        public void Write32(uint index, uint value)
        {
            if (index >= Size - sizeof(uint))
            {
                throw new ArgumentOutOfRangeException(nameof(index));
            }
            System.Runtime.CompilerServices.Unsafe.WriteUnaligned(ref _data[index], value);
        }

        public void Write64(uint index, ulong value)
        {
            if (index >= Size - sizeof(ulong))
            {
                throw new ArgumentOutOfRangeException(nameof(index));
            }
            System.Runtime.CompilerServices.Unsafe.WriteUnaligned(ref _data[index], value);
        }
    }
}

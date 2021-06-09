﻿using System;

namespace TinyNF.Unsafe
{
    /// <summary>
    /// An array of <see cref="Array256{T}" />.
    /// This struct is entirely safe, C# just cannot define it without unsafe yet. Same remarks as <see cref="RefArray{T}" />.
    /// </summary>
    public unsafe readonly ref struct Array256Array<T>
        where T : unmanaged
    {
        private readonly T*[] _values;

        public int Length => _values.Length;

        public Array256Array(int length, Array256Allocator<T> allocator)
        {
            _values = new T*[length];
            for (int n = 0; n < length; n++)
            {
                this[n] = new Array256<T>(allocator);
            }
        }

        public Array256<T> this[int n]
        {
            get
            {
                // Safe because anything in _values[n] must have been put there by the setter, which guarantees its length is 256
                return new Array256<T>(new Span<T>(_values[n], 256));
            }
            set
            {
                // AsPointer is safe here because value._values is stack-only and so is _values, thus the pointer can't escape
                _values[n] = (T*)System.Runtime.CompilerServices.Unsafe.AsPointer(ref value._values.GetPinnableReference());
            }
        }

        public Enumerator GetEnumerator()
        {
            return new Enumerator(this);
        }

        public ref struct Enumerator
        {
            private readonly Array256Array<T> _array;
            public int Index;

            public Enumerator(Array256Array<T> array)
            {
                _array = array;
                Index = -1;
            }

            public Array256<T> Current
            {
                get
                {
                    return _array[Index];
                }
            }

            public bool MoveNext()
            {
                Index++;
                return Index < _array.Length;
            }
        }
    }
}

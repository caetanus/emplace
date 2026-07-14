module emplace.vector;

// A GC-free, allocator-aware dynamic array — the automem.Vector replacement.
// Same shape (`Vector!(T, Allocator)`, Mallocator default) and hot-path API
// (put / popBack / clear / length / opSlice), but element-lifetime correct:
//
//   * RAII: `~this`, `clear`, `popBack`, and overwriting growth run each element's
//     resource release (`.free()` by convention if present, else its destructor)
//     — so a `Vector!(Uniq!T)` / `Vector!(Shared!T)` frees every element, no leak.
//   * smart-pointer safe: elements are MOVED into place (`moveEmplace`), never
//     blit-assigned over uninitialized memory, so move-only `Uniq` works and
//     `Shared` refcounts stay correct.
//   * ranges: `opSlice` yields the contiguous `T[]` (D's canonical range), plus
//     `front`/`back`/`empty`/`opIndex`/`length`. Copyable only when the element is
//     copyable (else the whole container is move-only, like `Uniq`).
//   * `shrinkToFit` gives excess capacity back to the allocator (std::vector's
//     `shrink_to_fit`) — capacity is otherwise KEPT on `clear`/`popBack` for
//     reuse, so a long-running buffer can be trimmed on demand.
//
// For a POD element (`__traits(isPOD, T)`) every path collapses to the old plain
// grow-by-doubling `memcpy` buffer — zero overhead, so existing POD/pointer users
// (byte buffers, `Conn*`, small records) are byte-for-byte unchanged.
//
// `Vector!bool` is a bit-packed specialization (like `std::vector<bool>`): each
// element is ONE bit in a `size_t` word array, so 1M flags cost 128KB not 1MB.
// `opIndex` returns a proxy bit-reference (assignable and bool-convertible);
// otherwise the API matches (put / length / front / back / opSlice range /
// shrinkToFit). It is always copyable (bool is trivially copyable).

import std.experimental.allocator : reallocate;
import std.experimental.allocator.mallocator : Mallocator;
import std.traits : hasElaborateDestructor;
import core.lifetime : moveEmplace;

struct Vector(T, Allocator = Mallocator)
{
    static if (is(T == bool))
    {
        // ---- bit-packed specialization (std::vector<bool>) -----------------
        import core.stdc.string : memcpy, memset;

        private alias Word = size_t;
        private enum size_t WBITS = Word.sizeof * 8;

        private Word* _words;
        private size_t _len; // number of bits in use
        private size_t _cap; // capacity in BITS (= nWords * WBITS)

        private static size_t wordsFor(size_t bits) @nogc nothrow pure
        {
            return (bits + WBITS - 1) / WBITS;
        }

        private void setBit(size_t i, bool b) @nogc nothrow @trusted
        {
            immutable mask = cast(Word) 1 << (i % WBITS);
            if (b)
                _words[i / WBITS] |= mask;
            else
                _words[i / WBITS] &= ~mask;
        }

        private bool getBit(size_t i) const @nogc nothrow @trusted
        {
            return (_words[i / WBITS] & (cast(Word) 1 << (i % WBITS))) != 0;
        }

        // Construct from an initial run of bits.
        this(scope const(bool)[] initial) @trusted
        {
            put(initial);
        }

        // Deep copy: clone the live words (bits are trivially copyable).
        this(this) @trusted
        {
            if (_len == 0)
            {
                _words = null;
                _cap = 0;
                return;
            }
            immutable nw = wordsFor(_len);
            auto old = _words;
            _words = cast(Word*) Allocator.instance.allocate(nw * Word.sizeof).ptr;
            assert(_words !is null, "out of memory");
            memcpy(_words, old, nw * Word.sizeof);
            _cap = nw * WBITS;
        }

        ~this() @trusted
        {
            if (_words !is null)
            {
                Allocator.instance.deallocate(
                    (cast(void*) _words)[0 .. wordsFor(_cap) * Word.sizeof]);
                _words = null;
                _len = _cap = 0;
            }
        }

        // Grow to hold at least `needBits`, doubling in whole words. Newly
        // allocated words are zeroed so `length =`/`back` after a grow see clean
        // bits (put sets each bit explicitly, so it doesn't rely on this).
        private void ensure(size_t needBits) @trusted
        {
            if (needBits <= _cap)
                return;
            size_t ncBits = _cap ? _cap * 2 : WBITS;
            while (ncBits < needBits)
                ncBits *= 2;
            immutable oldWords = wordsFor(_cap);
            immutable newWords = wordsFor(ncBits);
            auto block = (cast(void*) _words)[0 .. oldWords * Word.sizeof];
            immutable ok = reallocate(Allocator.instance, block, newWords * Word.sizeof);
            assert(ok, "out of memory");
            _words = cast(Word*) block.ptr;
            memset(_words + oldWords, 0, (newWords - oldWords) * Word.sizeof);
            _cap = newWords * WBITS;
        }

        /// Append one bit.
        void put(bool b) @trusted
        {
            ensure(_len + 1);
            setBit(_len, b);
            _len++;
        }

        /// Append a run of bits.
        void put(scope const(bool)[] xs) @trusted
        {
            if (xs.length == 0)
                return;
            ensure(_len + xs.length);
            foreach (b; xs)
            {
                setBit(_len, b);
                _len++;
            }
        }

        /// Drop the last bit (capacity retained).
        void popBack() @nogc nothrow
        {
            if (_len)
                _len--;
        }

        /// Reset to empty, keeping capacity for reuse.
        void clear() @nogc nothrow
        {
            _len = 0;
        }

        void reserve(size_t n) @trusted
        {
            ensure(n);
        }

        @property size_t length() const @nogc nothrow
        {
            return _len;
        }

        /// Resize. Growing zero-fills the new bits (both freshly allocated and
        /// any stale tail within existing capacity).
        @property void length(size_t n) @trusted
        {
            if (n > _len)
            {
                ensure(n);
                foreach (i; _len .. n)
                    setBit(i, false);
            }
            _len = n;
        }

        @property bool empty() const @nogc nothrow
        {
            return _len == 0;
        }

        bool front() const @nogc nothrow @trusted
        {
            assert(_len, "front of empty vector");
            return getBit(0);
        }

        bool back() const @nogc nothrow @trusted
        {
            assert(_len, "back of empty vector");
            return getBit(_len - 1);
        }

        /// Proxy bit-reference: assignable (`v[i] = true`) and bool-convertible
        /// (`if (v[i])`, `bool b = v[i]`) via `alias get this`.
        static struct BitRef
        {
            private Word* _w;
            private Word _mask;
            bool get() const @nogc nothrow @trusted
            {
                return (*_w & _mask) != 0;
            }

            alias get this;
            void opAssign(bool b) @nogc nothrow @trusted
            {
                if (b)
                    *_w |= _mask;
                else
                    *_w &= ~_mask;
            }
        }

        BitRef opIndex(size_t i) @nogc nothrow @trusted
        {
            assert(i < _len, "vector index out of range");
            return BitRef(&_words[i / WBITS], cast(Word) 1 << (i % WBITS));
        }

        bool opIndex(size_t i) const @nogc nothrow @trusted
        {
            assert(i < _len, "vector index out of range");
            return getBit(i);
        }

        size_t opDollar() const @nogc nothrow
        {
            return _len;
        }

        /// Give excess capacity back to the allocator (std::vector::shrink_to_fit):
        /// trim the word block down to what `_len` bits need.
        void shrinkToFit() @trusted
        {
            immutable needWords = wordsFor(_len);
            immutable haveWords = wordsFor(_cap);
            if (needWords == haveWords)
                return;
            if (needWords == 0)
            {
                if (_words !is null)
                    Allocator.instance.deallocate(
                        (cast(void*) _words)[0 .. haveWords * Word.sizeof]);
                _words = null;
                _cap = 0;
                return;
            }
            auto block = (cast(void*) _words)[0 .. haveWords * Word.sizeof];
            immutable ok = reallocate(Allocator.instance, block, needWords * Word.sizeof);
            assert(ok, "out of memory");
            _words = cast(Word*) block.ptr;
            _cap = needWords * WBITS;
        }

        /// Forward range over the bits (front→back) yielding `bool` by value.
        static struct Range
        {
            private const(Vector)* _v;
            private size_t _i, _n;

            @property bool empty() const @nogc nothrow
            {
                return _i >= _n;
            }

            @property bool front() const @nogc nothrow @trusted
            {
                return _v.getBit(_i);
            }

            void popFront() @nogc nothrow
            {
                _i++;
            }

            @property Range save() const @nogc nothrow
            {
                return this;
            }

            @property size_t length() const @nogc nothrow
            {
                return _n - _i;
            }
        }

        Range opSlice() const @nogc nothrow return
        {
            return Range(&this, 0, _len);
        }
    }
    else
    {
        // ---- general element storage --------------------------------------
        private T* _ptr;
        private size_t _len;
        private size_t _cap;

        private enum bool pod = __traits(isPOD, T);

        // Release one element's resource: `.free()` by convention, else its
        // destructor (covers Uniq/Shared/Weak and any RAII type); a no-op for POD.
        private static void disposeElem(ref T x) @trusted
        {
            static if (__traits(compiles, x.free()))
                x.free();
            else static if (hasElaborateDestructor!T)
                destroy!false(x);
        }

        // Construct from a slice of initial elements (copyable elements only).
        static if (__traits(compiles, { T t = T.init; T u = t; }))
            this(scope const(T)[] initial) @trusted
            {
                put(initial);
            }

        // Copy: deep-copy for a copyable element (POD ⇒ one memcpy); move-only
        // elements make the whole Vector move-only.
        static if (pod)
        {
            this(this) @trusted
            {
                if (_cap == 0)
                    return;
                import core.stdc.string : memcpy;

                auto old = _ptr;
                _ptr = cast(T*) Allocator.instance.allocate(_cap * T.sizeof).ptr;
                assert(_ptr !is null, "out of memory");
                memcpy(_ptr, old, _len * T.sizeof);
            }
        }
        else static if (__traits(compiles, { T t = T.init; T u = t; }))
        {
            this(this) @trusted
            {
                if (_len == 0)
                {
                    _ptr = null;
                    _cap = 0;
                    return;
                }
                import core.lifetime : emplace;

                auto old = _ptr;
                auto oldLen = _len;
                _ptr = cast(T*) Allocator.instance.allocate(_cap * T.sizeof).ptr;
                assert(_ptr !is null, "out of memory");
                foreach (i; 0 .. oldLen)
                    emplace(&_ptr[i], old[i]); // per-element copy ctor / postblit
            }
        }
        else
            @disable this(this); // move-only element ⇒ move-only container

        ~this() @trusted
        {
            if (_ptr !is null)
            {
                static if (!pod)
                    foreach (i; 0 .. _len)
                        disposeElem(_ptr[i]);
                Allocator.instance.deallocate((cast(void*) _ptr)[0 .. _cap * T.sizeof]);
                _ptr = null;
                _len = _cap = 0;
            }
        }

        // Grow the backing block. `reallocate` bit-moves the existing elements to
        // the new block (a relocation, valid for any movable D type) — no
        // per-element copy or destructor runs, which is exactly right for a move.
        private void ensure(size_t need) @trusted
        {
            if (need <= _cap)
                return;
            size_t nc = _cap ? _cap * 2 : 4;
            if (nc < need)
                nc = need;
            auto block = (cast(void*) _ptr)[0 .. _cap * T.sizeof];
            immutable ok = reallocate(Allocator.instance, block, nc * T.sizeof);
            assert(ok, "out of memory");
            _ptr = cast(T*) block.ptr;
            _cap = nc;
        }

        /// Append one element (moved into place — move-only elements work).
        void put(T x) @trusted
        {
            ensure(_len + 1);
            static if (pod)
                _ptr[_len] = x;
            else
                moveEmplace(x, _ptr[_len]);
            _len++;
        }

        /// Append a slice (bulk). Copyable elements only; a single memcpy for POD.
        static if (__traits(compiles, { T t = T.init; T u = t; }))
            void put(scope const(T)[] xs) @trusted
            {
                if (xs.length == 0)
                    return;
                ensure(_len + xs.length);
                static if (pod)
                {
                    import core.stdc.string : memcpy;

                    memcpy(_ptr + _len, xs.ptr, xs.length * T.sizeof);
                    _len += xs.length;
                }
                else
                {
                    import core.lifetime : emplace;

                    foreach (ref x; xs)
                    {
                        emplace(&_ptr[_len], x);
                        _len++;
                    }
                }
            }

        /// Drop the last element (its resource is released; capacity retained).
        void popBack() @trusted
        {
            if (_len)
            {
                _len--;
                static if (!pod)
                    disposeElem(_ptr[_len]);
            }
        }

        /// Reset to empty (releasing every element), keeping capacity for reuse.
        void clear() @trusted
        {
            static if (!pod)
                foreach (i; 0 .. _len)
                    disposeElem(_ptr[i]);
            _len = 0;
        }

        void reserve(size_t n) @trusted
        {
            ensure(n);
        }

        /// Give excess capacity back to the allocator (std::vector::shrink_to_fit):
        /// trim the block down to `_len` elements (a relocation — bitwise move,
        /// valid for any movable D type). Empty ⇒ the block is freed entirely.
        void shrinkToFit() @trusted
        {
            if (_cap == _len)
                return;
            if (_len == 0)
            {
                if (_ptr !is null)
                {
                    Allocator.instance.deallocate((cast(void*) _ptr)[0 .. _cap * T.sizeof]);
                    _ptr = null;
                    _cap = 0;
                }
                return;
            }
            auto block = (cast(void*) _ptr)[0 .. _cap * T.sizeof];
            immutable ok = reallocate(Allocator.instance, block, _len * T.sizeof);
            assert(ok, "out of memory");
            _ptr = cast(T*) block.ptr;
            _cap = _len;
        }

        @property size_t length() const @nogc nothrow
        {
            return _len;
        }

        /// Resize. Growing keeps capacity (reuse-friendly); for a POD element the
        /// new tail is uninitialized bytes (callers that grow-then-fill, e.g.
        /// raft's appendBytes). Only defined for POD — a non-POD grow would expose
        /// unconstructed elements.
        static if (pod)
            @property void length(size_t n) @trusted
            {
                ensure(n);
                _len = n;
            }

        @property bool empty() const @nogc nothrow
        {
            return _len == 0;
        }

        ref inout(T) front() inout @nogc nothrow @trusted return
        {
            assert(_len, "front of empty vector");
            return _ptr[0];
        }

        ref inout(T) back() inout @nogc nothrow @trusted return
        {
            assert(_len, "back of empty vector");
            return _ptr[_len - 1];
        }

        /// The contiguous slice — D's canonical range. @system like automem's (it
        /// aliases interior memory).
        inout(T)[] opSlice() inout @nogc nothrow @trusted return
        {
            return _ptr[0 .. _len];
        }

        ref inout(T) opIndex(size_t i) inout @nogc nothrow @trusted return
        {
            return _ptr[i];
        }

        size_t opDollar() const @nogc nothrow
        {
            return _len;
        }
    }
}

@nogc nothrow @system unittest // put/slice/clear/length reuse (POD fast path)
{
    Vector!ubyte v;
    ubyte[3] src = [1, 2, 3];
    v.put(src[]);
    v.put(cast(ubyte) 4);
    assert(v.length == 4 && v[] == cast(ubyte[])[1, 2, 3, 4]);
    assert(v.front == 1 && v.back == 4 && !v.empty);
    v.popBack();
    assert(v.length == 3 && v[$ - 1] == 3);

    immutable capBefore = v._cap;
    v.clear();
    assert(v.length == 0 && v._cap == capBefore); // capacity kept

    v.length = 2;
    v[0] = 9;
    v[1] = 8;
    assert(v[] == cast(ubyte[])[9, 8]);
}

@nogc nothrow @system unittest // deep copy is independent (POD)
{
    Vector!ubyte a;
    a.put(cast(ubyte) 7);
    auto b = a; // this(this) deep copy
    b.put(cast(ubyte) 8);
    assert(a.length == 1 && b.length == 2 && a[0] == 7);
    a[0] = 1;
    assert(b[0] == 7); // independent buffers
}

@nogc nothrow @system unittest // shrinkToFit trims excess capacity; empty frees block
{
    Vector!int v;
    foreach (i; 0 .. 100)
        v.put(i);
    v.length = 3; // len 3, cap still >= 100 (well, POD length setter keeps cap)
    assert(v._cap >= 100);
    v.shrinkToFit();
    assert(v._cap == 3 && v[0] == 0 && v[1] == 1 && v[2] == 2); // data preserved

    v.clear();
    v.shrinkToFit();
    assert(v._cap == 0 && v._ptr is null && v.empty); // fully freed at empty
    v.put(42); // usable again
    assert(v.front == 42);
}

version (unittest) private struct VCounter
{
    __gshared int live;
    int v; // 0 == moved-from (T.init after moveEmplace) — not counted
    this(int x) @nogc nothrow { v = x; live++; }
    this(this) @nogc nothrow { if (v != 0) live++; }
    ~this() @nogc nothrow { if (v != 0) live--; }
}

@nogc nothrow unittest // RAII element: ~this / popBack / clear release each
{
    VCounter.live = 0;
    {
        Vector!VCounter v;
        foreach (i; 0 .. 5)
            v.put(VCounter(i + 1)); // temp constructed then MOVED into the slot
        assert(v.length == 5 && VCounter.live == 5);
        v.popBack();
        assert(VCounter.live == 4);
        auto copy = v; // per-element copy ctor
        assert(copy.length == 4 && VCounter.live == 8);
        copy.clear();
        assert(VCounter.live == 4);
    } // both destructors run
    assert(VCounter.live == 0);
}

@nogc nothrow unittest // move-only element (Uniq): Vector is move-only, frees each
{
    import emplace.smartptr : Uniq;
    import core.lifetime : move;

    Vector!(Uniq!int) v;
    v.put(Uniq!int.make(1));
    v.put(Uniq!int.make(2));
    assert(v.length == 2 && v[0].get == 1 && v[1].get == 2);
    static assert(!__traits(compiles, { auto b = v; })); // move-only container
    auto moved = move(v);
    assert(moved.length == 2 && moved[1].get == 2);
} // each Uniq freed by ~Vector

@nogc nothrow @system unittest // Vector!bool: bit-packed store, proxy assign, range
{
    Vector!bool b;
    foreach (i; 0 .. 100)
        b.put(i % 3 == 0); // true at 0,3,6,...
    assert(b.length == 100);
    // packed: 100 bits fit in 2 words (16 bytes), not 100 bytes
    assert(b._cap <= 128); // capacity counted in bits, ≤ 2 words here

    assert(b[0] && !b[1] && b[3]);
    b[1] = true; // proxy assign
    assert(b[1]);
    b[1] = false;
    assert(!b[1]);
    assert(b.front == true && b.back == (99 % 3 == 0)); // back = b[99] = false

    // bool-convertible proxy in an expression
    int trues = 0;
    foreach (bit; b[]) // forward range yields bool
        if (bit)
            trues++;
    int expect = 0;
    foreach (i; 0 .. 100)
        if (i % 3 == 0)
            expect++;
    assert(trues == expect);
}

@nogc nothrow @system unittest // Vector!bool: length grow zero-fills, deep copy, shrink
{
    Vector!bool a;
    a.put(true);
    a.put(true);
    a.length = 10; // grow: bits 2..9 must be false
    assert(a.length == 10 && a[0] && a[1]);
    foreach (i; 2 .. 10)
        assert(!a[i]);

    auto c = a; // deep copy (independent words)
    c[5] = true;
    assert(c[5] && !a[5]);

    // shrink after draining
    foreach (i; 0 .. 1000)
        a.put(i % 2 == 0);
    immutable grown = a._cap;
    a.length = 4;
    a.shrinkToFit();
    assert(a._cap < grown && a._cap <= 64); // 4 bits → 1 word
    assert(a[0] && a[1] && !a[2] && !a[3]); // surviving prefix intact

    a.clear();
    a.shrinkToFit();
    assert(a.empty && a._words is null && a._cap == 0); // freed at empty
}

module emplace.deque;

// A GC-free double-ended queue — the emplace.Vector sibling for FIFO/LIFO work.
//
// Design: a circular buffer (ring) over ONE contiguous grow-by-doubling block,
// same allocator/RAII shape as emplace.Vector. O(1) amortized push/pop at BOTH
// ends and O(1) random access by logical index — the operations std::deque gives
// you, but in a single block instead of libstdc++'s map-of-chunks (simpler,
// cache-tight, enough for the small queues this targets: blocked-client lists).
//
// Element-lifetime correct like Vector: elements are MOVED into place
// (`moveEmplace`), `popFront`/`popBack`/`clear`/`~this` run each element's
// resource release (`.free()` or destructor), and the deque is copyable exactly
// when the element is (else move-only, like `Uniq`). Relocation on grow/shrink is
// a bitwise move (valid for any movable D type), so no per-element work there.
// For a POD element (`__traits(isPOD, T)`) every path collapses to plain memcpy —
// zero overhead. Capacity is a power of two so logical→physical is a mask.
//
// Ranges: `opSlice` yields a forward `Range` (empty/front/popFront/save) walking
// logical order; plus `front`/`back`/`opIndex`/`length`/`empty`.

import std.experimental.allocator.mallocator : Mallocator;
import std.traits : hasElaborateDestructor;
import core.lifetime : moveEmplace;

struct Deque(T, Allocator = Mallocator)
{
    private T* _ptr;
    private size_t _cap; // power of two (0 when unallocated)
    private size_t _head; // physical index of the front element (when _len > 0)
    private size_t _len;

    private enum bool pod = __traits(isPOD, T);

    private static void disposeElem(ref T x) @trusted
    {
        static if (__traits(compiles, x.free()))
            x.free();
        else static if (hasElaborateDestructor!T)
            destroy!false(x);
    }

    // Relocate `_len` elements (logical order) from the current ring into `dst`
    // (a fresh block, re-based to index 0) as a BITWISE MOVE — no copy ctors / no
    // destructors, valid for any movable D type. Two memcpys around the wrap.
    private void relocateInto(T* dst) @trusted
    {
        import core.stdc.string : memcpy;

        immutable first = _cap - _head;
        if (first >= _len)
            memcpy(dst, _ptr + _head, _len * T.sizeof);
        else
        {
            memcpy(dst, _ptr + _head, first * T.sizeof);
            memcpy(dst + first, _ptr, (_len - first) * T.sizeof);
        }
    }

    // Copy: deep-copy for a copyable element (POD ⇒ bitwise relocate); move-only
    // elements make the whole deque move-only.
    static if (pod)
    {
        this(this) @trusted
        {
            if (_len == 0)
            {
                _ptr = null;
                _cap = _head = 0;
                return;
            }
            auto src = _ptr, sc = _cap, sh = _head;
            _ptr = cast(T*) Allocator.instance.allocate(sc * T.sizeof).ptr;
            assert(_ptr !is null, "out of memory");
            // relocate reads _ptr/_cap/_head — restore src view for the memcpy
            auto keepP = _ptr;
            _ptr = src;
            _cap = sc;
            _head = sh;
            relocateInto(keepP);
            _ptr = keepP;
            _head = 0;
        }
    }
    else static if (__traits(compiles, { T t = T.init; T u = t; }))
    {
        this(this) @trusted
        {
            if (_len == 0)
            {
                _ptr = null;
                _cap = _head = 0;
                return;
            }
            import core.lifetime : emplace;

            auto src = _ptr, sc = _cap, sh = _head, n = _len;
            _ptr = cast(T*) Allocator.instance.allocate(sc * T.sizeof).ptr;
            assert(_ptr !is null, "out of memory");
            foreach (i; 0 .. n)
                emplace(&_ptr[i], src[(sh + i) & (sc - 1)]); // per-element copy
            _cap = sc;
            _head = 0;
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
                    disposeElem(_ptr[(_head + i) & (_cap - 1)]);
            Allocator.instance.deallocate((cast(void*) _ptr)[0 .. _cap * T.sizeof]);
            _ptr = null;
            _cap = _head = _len = 0;
        }
    }

    @property size_t length() const @nogc nothrow
    {
        return _len;
    }

    @property bool empty() const @nogc nothrow
    {
        return _len == 0;
    }

    private size_t phys(size_t logical) const @nogc nothrow
    {
        return (_head + logical) & (_cap - 1); // _cap is a power of two
    }

    // Grow to hold at least `need` elements, relocating the ring into a fresh
    // power-of-two block re-based to head 0.
    private void ensure(size_t need) @trusted
    {
        if (need <= _cap)
            return;
        size_t nc = _cap ? _cap * 2 : 4;
        while (nc < need)
            nc *= 2;
        auto nb = cast(T*) Allocator.instance.allocate(nc * T.sizeof).ptr;
        assert(nb !is null, "out of memory");
        if (_len)
            relocateInto(nb);
        if (_ptr !is null)
            Allocator.instance.deallocate((cast(void*) _ptr)[0 .. _cap * T.sizeof]);
        _ptr = nb;
        _cap = nc;
        _head = 0;
    }

    /// Append at the back (moved into place — move-only elements work).
    void pushBack(T x) @trusted
    {
        ensure(_len + 1);
        static if (pod)
            _ptr[phys(_len)] = x;
        else
            moveEmplace(x, _ptr[phys(_len)]);
        _len++;
    }

    /// Prepend at the front.
    void pushFront(T x) @trusted
    {
        ensure(_len + 1);
        _head = (_head + _cap - 1) & (_cap - 1);
        static if (pod)
            _ptr[_head] = x;
        else
            moveEmplace(x, _ptr[_head]);
        _len++;
    }

    /// Drop the front element (its resource is released; then maybe shrink).
    void popFront() @trusted
    {
        if (_len)
        {
            static if (!pod)
                disposeElem(_ptr[_head]);
            _head = (_head + 1) & (_cap - 1);
            _len--;
            maybeShrink();
        }
    }

    /// Drop the back element (releases its resource; then maybe shrink).
    void popBack() @trusted
    {
        if (_len)
        {
            static if (!pod)
                disposeElem(_ptr[phys(_len - 1)]);
            _len--;
            maybeShrink();
        }
    }

    // Give memory back as the deque empties: free the block entirely at empty,
    // else halve capacity once the load drops to a quarter (hysteresis: after a
    // shrink the load is 1/2, so it won't immediately re-grow or re-shrink).
    // Relocation is a bitwise move (elements already had their dtor run on pop).
    private void maybeShrink() @trusted
    {
        if (_len == 0)
        {
            if (_ptr !is null)
            {
                Allocator.instance.deallocate((cast(void*) _ptr)[0 .. _cap * T.sizeof]);
                _ptr = null;
                _cap = _head = 0;
            }
            return;
        }
        if (_cap <= 8 || _len > _cap / 4)
            return;
        immutable nc = _cap / 2; // power of two ≥ 4, and nc ≥ _len (len ≤ cap/4)
        auto nb = cast(T*) Allocator.instance.allocate(nc * T.sizeof).ptr;
        assert(nb !is null, "out of memory");
        relocateInto(nb);
        Allocator.instance.deallocate((cast(void*) _ptr)[0 .. _cap * T.sizeof]);
        _ptr = nb;
        _cap = nc;
        _head = 0;
    }

    ref inout(T) front() inout @nogc nothrow @trusted return
    {
        assert(_len, "front of empty deque");
        return _ptr[_head];
    }

    ref inout(T) back() inout @nogc nothrow @trusted return
    {
        assert(_len, "back of empty deque");
        return _ptr[(_head + _len - 1) & (_cap - 1)];
    }

    ref inout(T) opIndex(size_t i) inout @nogc nothrow @trusted return
    {
        assert(i < _len, "deque index out of range");
        return _ptr[(_head + i) & (_cap - 1)];
    }

    /// Reset to empty (releasing every element), keeping capacity for reuse.
    void clear() @trusted
    {
        static if (!pod)
            foreach (i; 0 .. _len)
                disposeElem(_ptr[(_head + i) & (_cap - 1)]);
        _len = 0;
        _head = 0;
    }

    size_t opDollar() const @nogc nothrow
    {
        return _len;
    }

    /// Forward range over the elements in logical (front→back) order. A view: it
    /// does not consume the deque and `save` snapshots the position.
    static struct Range
    {
        private const(Deque)* _d;
        private size_t _i, _n;

        @property bool empty() const @nogc nothrow { return _i >= _n; }
        @property ref const(T) front() const @nogc nothrow @trusted return
        {
            return (*_d)[_i];
        }
        void popFront() @nogc nothrow { _i++; }
        @property Range save() const @nogc nothrow { return this; }
        @property size_t length() const @nogc nothrow { return _n - _i; }
    }

    Range opSlice() const @nogc nothrow return
    {
        return Range(&this, 0, _len);
    }
}

@trusted unittest // push/pop both ends + wrap + index order (POD fast path)
{
    Deque!int d;
    foreach (i; 0 .. 4)
        d.pushBack(i); // [0 1 2 3]
    assert(d.length == 4 && d.front == 0 && d.back == 3);
    d.popFront();
    d.popFront(); // [2 3]
    d.pushBack(4);
    d.pushBack(5); // [2 3 4 5] — wraps
    assert(d.length == 4);
    foreach (i, v; [2, 3, 4, 5])
        assert(d[i] == v);
    d.pushFront(1); // [1 2 3 4 5] — grow+relocate
    assert(d.front == 1 && d.length == 5);
    // range walks logical order
    int[] got;
    foreach (v; d[])
        got ~= v;
    assert(got == [1, 2, 3, 4, 5]);
    d.popBack();
    assert(d.back == 4 && d.length == 4);
}

@trusted unittest // FIFO drain order + memory shrink (long-running safety)
{
    Deque!int d;
    foreach (i; 0 .. 1000)
        d.pushBack(i);
    immutable grown = d._cap;
    foreach (i; 0 .. 999)
    {
        assert(d.front == i);
        d.popFront();
    }
    assert(d.length == 1 && d._cap < grown); // capacity shrank while draining
    d.popFront();
    assert(d.empty && d._cap == 0 && d._ptr is null); // block freed at empty
    d.pushBack(42);
    assert(d.front == 42 && d._cap >= 4);
}

@trusted unittest // deep copy is independent (POD)
{
    Deque!int a;
    a.pushBack(7);
    a.pushBack(8);
    auto b = a; // this(this) deep copy
    b.pushBack(9);
    assert(a.length == 2 && b.length == 3);
    a[0] = 1;
    assert(b[0] == 7); // independent buffers
}

version (unittest) private struct DCounter
{
    __gshared int live;
    int v; // 0 == moved-from
    this(int x) @nogc nothrow { v = x; live++; }
    this(this) @nogc nothrow { if (v != 0) live++; }
    ~this() @nogc nothrow { if (v != 0) live--; }
}

@nogc nothrow unittest // RAII element: pop/clear/~this release; copy is deep
{
    DCounter.live = 0;
    {
        Deque!DCounter d;
        foreach (i; 0 .. 5)
            d.pushBack(DCounter(i + 1)); // moved into the ring
        assert(d.length == 5 && DCounter.live == 5);
        d.popFront();
        d.popBack();
        assert(DCounter.live == 3);
        auto copy = d; // per-element copy ctor
        assert(copy.length == 3 && DCounter.live == 6);
        copy.clear();
        assert(DCounter.live == 3);
    }
    assert(DCounter.live == 0);
}

@nogc nothrow unittest // move-only element (Uniq): deque is move-only, frees each
{
    import emplace.smartptr : Uniq;
    import core.lifetime : move;

    Deque!(Uniq!int) d;
    d.pushBack(Uniq!int.make(1));
    d.pushFront(Uniq!int.make(2)); // [2 1]
    assert(d.length == 2 && d.front.get == 2 && d.back.get == 1);
    static assert(!__traits(compiles, { auto b = d; })); // move-only container
    auto moved = move(d);
    assert(moved.length == 2 && moved.front.get == 2);
} // each Uniq freed by ~Deque

module emplace.hashmap;

// Unordered (hash) container — a @nogc open-addressing hash table with malloc'd
// string keys mapped to owned values. It is the proven table extracted from the
// dreads database (battle-tested under a Redis/Valkey workload), generalized so
// the value can be ANYTHING that owns a resource:
//   * a type with `void free()` (the RAII-by-convention style), or
//   * any type with a destructor — including this library's own `Uniq` / `Shared`
//     / `Weak` smart pointers (a `HashMap!(Uniq!T)` frees each value's box on
//     removal), or
//   * plain data.
// The table calls `.free()` if the value has it, else runs the destructor, on
// overwrite / remove / clear / free. Values are moved in (so move-only values
// like `Uniq` work). Keys are always `const(char)[]`.
//
// Instances are plain data (no destructor, no copy hooks) so they can live
// inside a union — call `free()` explicitly when done.

import core.lifetime : moveEmplace;
import core.stdc.stdlib : calloc, malloc, cfree = free;
import core.stdc.string : memcpy;
import std.traits : hasElaborateDestructor;

private const(char)[] mallocDup(scope const(char)[] s) @nogc nothrow @trusted
{
    if (s.length == 0)
        return "";
    auto p = cast(char*) malloc(s.length);
    assert(p !is null, "out of memory");
    memcpy(p, s.ptr, s.length);
    return p[0 .. s.length];
}

private void freeSlice(scope const(char)[] s) @nogc nothrow @trusted
{
    if (s.length)
        cfree(cast(void*) s.ptr);
}

private ulong fnv1a(scope const(char)[] s) @nogc nothrow
{
    ulong h = 0xcbf2_9ce4_8422_2325;
    foreach (c; s)
    {
        h ^= c;
        h *= 0x100_0000_01b3;
    }
    return h;
}

private enum SlotState : ubyte
{
    empty,
    used,
    tomb
}

// STL-consistent (std::unordered_map): a real destructor frees the table and
// cascades to each value, and a copy is an independent deep clone — so the map
// composes with the smart pointers (a `Shared!X`/`Uniq!X` holding a `HashMap`
// cleans up with no leak and no manual `.free()`), exactly like its sibling
// `Vector`/`Map`/`Deque`.
//
// It is SAFE as a by-value UNION member (e.g. RObj's `union { SmallHash; SmallSet;
// ... }`): D never auto-runs a union member's destructor (it can't know which
// member is active), so the union's owner keeps freeing by tag and there is no
// double-free — no dtorless variant is needed. The `union member dtor` unittest
// at the bottom pins that language guarantee.
struct HashMap(V)
{
    private static struct Slot
    {
        SlotState state;
        ulong hash;
        const(char)[] key;
        V val;
    }

    private Slot* slots;
    private size_t cap; // power of two; 0 until first insert
    private size_t used;
    private size_t fill; // live + tombstones

    /// RAII: destruction releases the table and every value. Idempotent (free()
    /// nulls the table, so a redundant free/dtor is a no-op).
    ~this()
    {
        free();
    }

    static if (__traits(isCopyable, V))
        /// Value semantics: a copy is an independent deep clone (own key bytes,
        /// each value copied) — never a shared bitwise alias that double-frees.
        this(this) @trusted
        {
            auto src = slots;
            immutable scap = cap;
            slots = null;
            cap = used = fill = 0;
            foreach (i; 0 .. scap)
                if (src[i].state == SlotState.used)
                    set(src[i].key, src[i].val); // dups the key, copies the value
        }
    else
        @disable this(this); // move-only value ⇒ move-only map (like Vector)

    // Run a value's resource release: `.free()` by convention if present, else
    // its destructor (covers Uniq/Shared/Weak and any RAII type; a no-op for POD).
    private static void disposeVal(ref V v)
    {
        static if (__traits(compiles, v.free()))
            v.free();
        else static if (hasElaborateDestructor!V)
            destroy!false(v); // runs Uniq/Shared/Weak (and any RAII) dtor
        // else: plain data, nothing to release
    }

    @property size_t length() const
    {
        return used;
    }

    @property bool empty() const
    {
        return used == 0;
    }

    /// Releases every entry and the table itself.
    void free()
    {
        clear();
        if (slots !is null)
        {
            cfree(slots);
            slots = null;
            cap = 0;
        }
    }

    /// Removes every entry, keeping the allocated table.
    void clear()
    {
        foreach (i; 0 .. cap)
        {
            if (slots[i].state == SlotState.used)
            {
                freeSlice(slots[i].key);
                disposeVal(slots[i].val);
            }
            slots[i] = Slot.init;
        }
        used = fill = 0;
    }

    private size_t findSlot(scope const(char)[] k, ulong h, out bool found) const
    {
        size_t mask = cap - 1;
        size_t i = h & mask;
        size_t firstTomb = size_t.max;
        while (true)
        {
            final switch (slots[i].state)
            {
            case SlotState.empty:
                found = false;
                return firstTomb != size_t.max ? firstTomb : i;
            case SlotState.tomb:
                if (firstTomb == size_t.max)
                    firstTomb = i;
                break;
            case SlotState.used:
                if (slots[i].hash == h && slots[i].key == k)
                {
                    found = true;
                    return i;
                }
                break;
            }
            i = (i + 1) & mask;
        }
    }

    private void rehash(size_t ncap) @trusted
    {
        auto nslots = cast(Slot*) calloc(ncap, Slot.sizeof);
        assert(nslots !is null, "out of memory");
        size_t mask = ncap - 1;
        foreach (i; 0 .. cap)
        {
            if (slots[i].state != SlotState.used)
                continue;
            size_t j = slots[i].hash & mask;
            while (nslots[j].state == SlotState.used)
                j = (j + 1) & mask;
            moveEmplace(slots[i], nslots[j]); // move the whole slot (works for move-only values)
        }
        if (slots !is null)
            cfree(slots);
        slots = nslots;
        cap = ncap;
        fill = used;
    }

    private void maybeGrow()
    {
        if (fill * 4 < cap * 3)
            return;
        size_t ncap = cap == 0 ? 16 : (used * 2 >= cap ? cap * 2 : cap);
        rehash(ncap);
    }

    /// Insert or overwrite, taking ownership of `val` (moved in — move-only
    /// values like Uniq work). Returns true if the key was new.
    bool set(scope const(char)[] k, V val)
    {
        maybeGrow();
        auto h = fnv1a(k);
        bool found;
        auto i = findSlot(k, h, found);
        if (found)
        {
            disposeVal(slots[i].val);
            moveEmplace(val, slots[i].val);
            return false;
        }
        if (slots[i].state == SlotState.empty)
            fill++;
        slots[i].state = SlotState.used;
        slots[i].hash = h;
        slots[i].key = mallocDup(k);
        moveEmplace(val, slots[i].val);
        used++;
        return true;
    }

    /// Pointer to the live value, or null. Valid until the next set/del.
    inout(V)* get(scope const(char)[] k) inout
    {
        if (used == 0)
            return null;
        bool found;
        auto i = findSlot(k, fnv1a(k), found);
        return found ? &slots[i].val : null;
    }

    bool contains(scope const(char)[] k) const
    {
        return get(k) !is null;
    }

    alias exists = contains;

    /// The table's own stable copy of `k`'s key bytes, or null when absent. The
    /// bytes outlive rehashes (rehash moves the slot array, never the key
    /// memory) and stay valid until the entry is removed — so a caller can index
    /// a key by slice without allocating a second copy.
    const(char)[] storedKey(scope const(char)[] k) @nogc nothrow @trusted
    {
        if (used == 0)
            return null;
        bool found;
        auto i = findSlot(k, fnv1a(k), found);
        return found ? slots[i].key : null;
    }

    bool remove(scope const(char)[] k)
    {
        if (used == 0)
            return false;
        bool found;
        auto i = findSlot(k, fnv1a(k), found);
        if (!found)
            return false;
        freeSlice(slots[i].key);
        disposeVal(slots[i].val);
        slots[i] = Slot.init;
        slots[i].state = SlotState.tomb;
        used--;
        return true;
    }

    alias del = remove;

    /// Remove `k` without releasing its value; the caller takes ownership.
    bool steal(scope const(char)[] k, out V val)
    {
        if (used == 0)
            return false;
        bool found;
        auto i = findSlot(k, fnv1a(k), found);
        if (!found)
            return false;
        freeSlice(slots[i].key);
        moveEmplace(slots[i].val, val);
        slots[i] = Slot.init;
        slots[i].state = SlotState.tomb;
        used--;
        return true;
    }

    // Index-based iteration for @nogc callers that cannot afford closures.
    @property size_t capacity() const
    {
        return cap;
    }

    bool slotLive(size_t i) const
    {
        return slots[i].state == SlotState.used;
    }

    const(char)[] keyAt(size_t i) const
    {
        return slots[i].key;
    }

    inout(V)* valAt(size_t i) inout
    {
        return &slots[i].val;
    }

    int opApply(scope int delegate(const(char)[] key, ref V val) @nogc nothrow dg) @nogc nothrow
    {
        foreach (i; 0 .. cap)
        {
            if (slots[i].state != SlotState.used)
                continue;
            if (auto r = dg(slots[i].key, slots[i].val))
                return r;
        }
        return 0;
    }
}

/// std::unordered_set — string keys, no value.
struct HashSet
{
    private struct Unit
    {
    }

    private HashMap!Unit tbl;

    // HashSet is a concrete (non-template) struct, so its methods do not infer
    // attributes the way HashMap's do — annotate them explicitly.
    void add(scope const(char)[] k) @nogc nothrow
    {
        tbl.set(k, Unit.init);
    }

    bool remove(scope const(char)[] k) @nogc nothrow
    {
        return tbl.remove(k);
    }

    bool contains(scope const(char)[] k) const @nogc nothrow
    {
        return tbl.contains(k);
    }

    bool opBinaryRight(string op : "in")(scope const(char)[] k) const @nogc nothrow
    {
        return contains(k);
    }

    @property size_t length() const @nogc nothrow
    {
        return tbl.length;
    }

    void free() @nogc nothrow
    {
        tbl.free();
    }

    int opApply(scope int delegate(const(char)[]) @nogc nothrow dg) @nogc nothrow
    {
        return tbl.opApply((const(char)[] k, ref Unit _) => dg(k));
    }
}

@nogc nothrow unittest // PROOF: containers compose "downhill" — a HashMap of a
{ //  Map of a Vector, freed in one cascade (HashMap -> Map dtor -> Vector dtor)
    import emplace.map : Map;
    import emplace.vector : Vector;
    import core.lifetime : move;

    HashMap!(Map!(const(char)[], Vector!int)) outer;
    scope (exit)
        outer.free();

    Map!(const(char)[], Vector!int) inner;
    Vector!int v;
    v.put(1);
    v.put(2);
    v.put(3);
    inner.set("nums", move(v)); // Map owns a Vector
    outer.set("k", move(inner)); // HashMap owns the Map owns the Vector

    // read down all three levels
    auto m = outer.get("k");
    assert(m !is null);
    auto vec = m.get("nums");
    assert(vec !is null && (*vec)[].length == 3 && (*vec)[0] == 1 && (*vec)[2] == 3);
    // outer.free() (scope exit) releases the whole tree in one cascade.
}

version (unittest) private struct Owned // a `.free()`-convention value
{
    __gshared int live;
    char* p;
    static Owned of(int tag) @nogc nothrow
    {
        Owned o;
        o.p = cast(char*) malloc(1);
        *o.p = cast(char) tag;
        live++;
        return o;
    }

    void free() @nogc nothrow
    {
        if (p)
        {
            cfree(p);
            p = null;
            live--;
        }
    }
}

@nogc nothrow unittest // .free()-convention values: set/overwrite/del/clear/free
{
    Owned.live = 0;
    HashMap!Owned m;
    assert(m.set("a", Owned.of(1)) && !m.set("a", Owned.of(2))); // overwrite frees old
    assert(m.length == 1 && Owned.live == 1);
    m.set("b", Owned.of(3));
    assert(m.remove("a") && Owned.live == 1); // "b" still live
    m.free();
    assert(Owned.live == 0); // everything released
}

@nogc nothrow unittest // PROOF: HashMap owns unique_ptr / shared_ptr / weak_ptr
{
    import emplace.smartptr : Uniq, Shared, Weak;

    static struct C
    {
        __gshared int live;
        int v;
        this(int x) @nogc nothrow
        {
            v = x;
            live++;
        }

        ~this() @nogc nothrow
        {
            live--;
        }
    }

    // --- unique_ptr values (move-only; moved into the table, dtor frees) ---
    C.live = 0;
    {
        HashMap!(Uniq!C) m;
        scope (exit)
            m.free();
        m.set("x", Uniq!C.make(1));
        m.set("y", Uniq!C.make(2));
        assert(m.length == 2 && C.live == 2);
        assert(m.get("x").get.v == 1); // borrow through the table
        assert(m.remove("x") && C.live == 1); // removal runs the Uniq dtor
        // steal: move ownership back out, no free
        Uniq!C out_;
        assert(m.steal("y", out_) && out_.get.v == 2 && C.live == 1);
        assert(m.length == 0);
    } // out_ dies here
    assert(C.live == 0);

    // --- shared_ptr values (refcounted) ---
    C.live = 0;
    {
        HashMap!(Shared!C) m;
        scope (exit)
            m.free();
        auto sp = Shared!C.make(7);
        m.set("s", sp); // table holds a second strong ref
        assert(sp.useCount == 2 && C.live == 1);
        assert(m.get("s").get.v == 7);
        m.remove("s"); // table's ref dropped
        assert(sp.useCount == 1 && C.live == 1);
    }
    assert(C.live == 0);

    // --- weak_ptr values (non-owning observers) ---
    C.live = 0;
    {
        auto sp = Shared!C.make(9);
        HashMap!(Weak!C) m;
        scope (exit)
            m.free();
        m.set("w", sp.weaken());
        assert(!m.get("w").expired && C.live == 1);
        // the object stays alive because `sp` still owns it, not the weak table
        assert(m.get("w").lock().get.v == 9);
    }
    assert(C.live == 0);
}

@nogc unittest // rehash under load + HashSet
{
    HashMap!int m;
    scope (exit)
        m.free();
    foreach (i; 0 .. 1000)
        m.set(itoa(i), i);
    assert(m.length == 1000 && *m.get(itoa(999)) == 999);
    foreach (i; 0 .. 500)
        assert(m.remove(itoa(i)));
    assert(m.length == 500 && !m.contains(itoa(42)) && m.contains(itoa(542)));

    HashSet s;
    scope (exit)
        s.free();
    s.add("a");
    s.add("a");
    assert(s.length == 1 && "a" in s && !("b" in s));
}

// PROOF that a HashMap (which now has `~this`) is safe as a by-value UNION member
// — the pattern RObj uses (`union { SmallHash; SmallSet; ... }`). D never
// auto-runs a union member's destructor (it can't know which member is active),
// so the union's owner frees by tag with no double-free and no leak.
@nogc nothrow unittest
{
    // (a) the language guarantee itself: a union member's ~this is NOT auto-called.
    static int ticks;
    static struct Ticker
    {
        ~this() @nogc nothrow { ticks++; }
    }

    static struct HolderA
    {
        union
        {
            Ticker t;
            int i;
        }
    }

    ticks = 0;
    {
        HolderA h;
        h.i = 7;
    } // scope exit: HolderA.~this does NOT run the union member Ticker's dtor
    assert(ticks == 0);

    // (b) a HashMap-in-union, freed BY TAG, releases each value exactly once —
    // no leak, no double-free.
    static int vfrees;
    static struct Val
    {
        void free() @nogc nothrow { vfrees++; }
    }

    static struct Tagged
    {
        ubyte tag; // 0 = `a` is the active member
        union
        {
            HashMap!Val a;
            HashMap!Val b;
        }

        void free() @nogc nothrow @trusted
        {
            if (tag == 0)
                a.free();
            else
                b.free();
        }
    }

    vfrees = 0;
    {
        Tagged tg;
        tg.tag = 0;
        tg.a.set("x", Val());
        tg.a.set("y", Val());
        tg.free(); // frees a's two values by tag
    } // scope exit: a.~this is NOT auto-run (union member)
    assert(vfrees == 2); // each value freed exactly once
}

version (unittest) private const(char)[] itoa(int i) @nogc nothrow
{
    import core.stdc.stdio : snprintf;

    static char[16] buf;
    immutable n = snprintf(buf.ptr, buf.length, "%d", i);
    return buf[0 .. n];
}

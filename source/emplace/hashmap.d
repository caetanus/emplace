module emplace.hashmap;

// Unordered (hash) containers — the C++ std::unordered_map / unordered_set of
// the set. Open addressing with linear probing and backward-shift deletion (no
// tombstones), power-of-two capacity, grow at 0.75 load. Allocator-aware via
// std.experimental.allocator (Mallocator default); @nogc when the allocator is.
// Keys hash with druntime's hashOf and compare with ==.

import std.experimental.allocator : makeArray, dispose;
import std.experimental.allocator.mallocator : Mallocator;

private enum ubyte SLOT_EMPTY = 0;
private enum ubyte SLOT_USED = 1;

/// std::unordered_map. Move-only (owns a malloc'd table).
struct HashMap(K, V, Allocator = Mallocator)
{
    private struct Slot
    {
        K key;
        V val;
        ubyte state; // SLOT_EMPTY / SLOT_USED
    }

    private Slot[] slots;
    private size_t count;

    @disable this(this);

    ~this() @trusted
    {
        if (slots.length)
            Allocator.instance.dispose(slots);
    }

    @property size_t length() const
    {
        return count;
    }

    @property bool empty() const
    {
        return count == 0;
    }

    private size_t slotFor(const ref K key) const @trusted
    {
        immutable mask = slots.length - 1;
        size_t i = hashOf(key) & mask;
        while (slots[i].state == SLOT_USED && slots[i].key != key)
            i = (i + 1) & mask;
        return i;
    }

    private void grow() @trusted
    {
        immutable newCap = slots.length ? slots.length * 2 : 8;
        auto old = slots;
        slots = Allocator.instance.makeArray!Slot(newCap); // states start EMPTY (0)
        count = 0;
        foreach (ref s; old)
            if (s.state == SLOT_USED)
                set(s.key, s.val);
        if (old.length)
            Allocator.instance.dispose(old);
    }

    /// Insert or overwrite.
    void set(K key, V val) @trusted
    {
        if ((count + 1) * 4 >= slots.length * 3) // load factor 0.75
            grow();
        immutable i = slotFor(key);
        if (slots[i].state != SLOT_USED)
        {
            slots[i].state = SLOT_USED;
            slots[i].key = key;
            count++;
        }
        slots[i].val = val;
    }

    /// Pointer to the stored value, or null.
    V* get(K key) @trusted return
    {
        if (count == 0)
            return null;
        immutable i = slotFor(key);
        return slots[i].state == SLOT_USED ? &slots[i].val : null;
    }

    bool contains(K key) @trusted
    {
        return get(key) !is null;
    }

    /// Remove; returns true if present. Backward-shift keeps the probe chains
    /// intact without tombstones.
    bool remove(K key) @trusted
    {
        if (count == 0)
            return false;
        immutable mask = slots.length - 1;
        size_t i = slotFor(key);
        if (slots[i].state != SLOT_USED)
            return false;
        size_t j = i;
        while (true)
        {
            j = (j + 1) & mask;
            if (slots[j].state != SLOT_USED)
                break;
            immutable home = hashOf(slots[j].key) & mask;
            // if slot j's ideal home is "not after" i (in circular order), shift it back
            immutable canMove = (i <= j) ? (home <= i || home > j) : (home <= i && home > j);
            if (canMove)
            {
                slots[i] = slots[j];
                i = j;
            }
        }
        slots[i].state = SLOT_EMPTY;
        slots[i] = Slot.init;
        count--;
        return true;
    }

    void clear() @trusted
    {
        foreach (ref s; slots)
            s = Slot.init;
        count = 0;
    }

    /// Iterate key/value pairs (unspecified order).
    int opApply(scope int delegate(ref K, ref V) dg)
    {
        foreach (ref s; slots)
            if (s.state == SLOT_USED)
                if (auto r = dg(s.key, s.val))
                    return r;
        return 0;
    }
}

/// std::unordered_set — a HashMap with no value.
struct HashSet(K, Allocator = Mallocator)
{
    private struct Unit
    {
    }

    private HashMap!(K, Unit, Allocator) tbl;

    @disable this(this);

    void add(K key)
    {
        tbl.set(key, Unit.init);
    }

    bool remove(K key)
    {
        return tbl.remove(key);
    }

    bool contains(K key)
    {
        return tbl.contains(key);
    }

    bool opBinaryRight(string op : "in")(K key)
    {
        return contains(key);
    }

    @property size_t length() const
    {
        return tbl.length;
    }

    @property bool empty() const
    {
        return tbl.empty;
    }

    void clear()
    {
        tbl.clear();
    }

    int opApply(scope int delegate(ref K) dg)
    {
        return tbl.opApply((ref K k, ref Unit _) => dg(k));
    }
}

unittest // HashMap: insert/overwrite/lookup/remove
{
    HashMap!(string, int) m;
    m.set("a", 1);
    m.set("b", 2);
    m.set("a", 10); // overwrite
    assert(m.length == 2);
    assert(*m.get("a") == 10 && *m.get("b") == 2);
    assert(m.get("z") is null && m.contains("a") && !m.contains("z"));
    assert(m.remove("a") && !m.contains("a") && m.length == 1);
    assert(!m.remove("a"));
}

unittest // grows and stays correct across many keys, then removals
{
    HashMap!(int, int) m;
    foreach (i; 0 .. 1000)
        m.set(i, i * i);
    assert(m.length == 1000);
    foreach (i; 0 .. 1000)
        assert(*m.get(i) == i * i);
    foreach (i; 0 .. 1000)
        if (i % 3 == 0)
            assert(m.remove(i));
    foreach (i; 0 .. 1000)
        assert((m.get(i) is null) == (i % 3 == 0));

    int seen = 0;
    foreach (ref k, ref v; m)
    {
        assert(v == k * k);
        seen++;
    }
    assert(seen == m.length);
}

unittest // HashSet
{
    HashSet!string s;
    s.add("x");
    s.add("y");
    s.add("x"); // dedup
    assert(s.length == 2 && "x" in s && !("z" in s));
    assert(s.remove("x") && !("x" in s));
}

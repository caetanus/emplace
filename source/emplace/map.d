module emplace.map;

// @nogc ordered containers — a classic CLRS red-black tree, plus an OrderedSet
// built on it. Neither automem nor Phobos offers a @nogc associative container
// (std.container.rbtree is GC-backed; automem ships only Vector), so the tree
// is hand-rolled: O(log n) insert/lookup/remove, in-order (sorted-key)
// iteration, nodes allocated through a std.experimental.allocator allocator
// (Mallocator by default — pass any other, e.g. a Region/FreeList arena, as the
// third template argument) and freed/recycled explicitly.
//
// Keys compare with `cmpKey` (byte-lexicographic for const(char)[]). Both
// containers are copyable exactly when their key/value is (a deep clone of the
// node graph — structure and colors preserved, own recycle pool), matching
// std::map/std::set; a move-only key/value (e.g. `Uniq`) makes them move-only,
// so a bitwise copy can never double-free the raw node graph.

import std.experimental.allocator : make, dispose;
import std.experimental.allocator.mallocator : Mallocator;

private int cmpKey(K)(const K a, const K b) @nogc nothrow
{
    static if (is(K : const(char)[]))
    {
        immutable n = a.length < b.length ? a.length : b.length;
        foreach (i; 0 .. n)
        {
            if (a[i] != b[i])
                return a[i] < b[i] ? -1 : 1;
        }
        if (a.length != b.length)
            return a.length < b.length ? -1 : 1;
        return 0;
    }
    else
        return a < b ? -1 : (a > b ? 1 : 0);
}

private enum Color : ubyte
{
    red,
    black
}

// Hint the CPU to pull a node's cache line while we still work on the current
// one — a tree descent is a dependent pointer-chase, so prefetching both children
// hides most of the next level's miss latency. No-op outside LDC.
private void prefetchR(const(void)* p) @nogc nothrow pure @trusted
{
    version (LDC)
    {
        import ldc.intrinsics : llvm_prefetch;

        llvm_prefetch(p, 0, 3, 1); // read, high locality, data cache
    }
}

struct Map(K, V, Allocator = Mallocator)
{
    private struct Node
    {
        K key;
        V val;
        Node* left, right, parent;
        Color color;
    }

    private Node* root;
    private size_t count;
    private Node* freePool; // recycled node memory (singly linked via .parent)
    private Node* _min; // cached leftmost node (rb_first_cached): O(1) find-min for
    // the consuming drain / any min query. A new node is the min iff inserted as
    // the left child of the current min; removing the min advances it to successor.

    // Copyable when both key and value are copyable — a deep clone of the node
    // graph (structure + colors preserved; the copy does NOT share the source's
    // recycle pool). A move-only key/value (e.g. `Uniq`) makes the map move-only.
    static if (__traits(compiles, { K k = K.init; auto kc = k; V v = V.init; auto vc = v; }))
    {
        this(this) @trusted
        {
            auto srcRoot = root; // fields were bit-copied from the source
            root = cloneSubtree(srcRoot, null);
            freePool = null; // a fresh map's own recycle pool
            _min = root is null ? null : minimum(root); // clone owns its own min ptr
            // `count` is already the source's count (correct for the copy)
        }

        // Deep-clone a subtree, copy-constructing each key/value and preserving
        // the red-black structure + colors (source is valid ⇒ the clone is).
        // Lives inside the copyable branch so a move-only key/value never
        // instantiates the (impossible) element copy.
        private static Node* cloneSubtree(Node* s, Node* parent) @trusted
        {
            if (s is null)
                return null;
            import core.lifetime : emplace;

            auto n = cast(Node*) Allocator.instance.allocate(Node.sizeof).ptr;
            assert(n !is null, "out of memory");
            emplace(&n.key, s.key); // copy ctor / postblit
            emplace(&n.val, s.val);
            n.color = s.color;
            n.parent = parent;
            n.left = cloneSubtree(s.left, n);
            n.right = cloneSubtree(s.right, n);
            return n;
        }
    }
    else
        @disable this(this); // move-only key/value ⇒ move-only map

    ~this() @nogc nothrow
    {
        clear();
    }

    @property size_t length() const @nogc nothrow
    {
        return count;
    }

    @property bool empty() const @nogc nothrow
    {
        return count == 0;
    }

    private Node* alloc(K key, V val) @nogc nothrow @trusted
    {
        Node* n;
        if (freePool !is null) // reuse a recycled node — no malloc
        {
            n = freePool;
            freePool = n.parent;
        }
        else
            n = Allocator.instance.make!Node;
        n.key = key;
        n.val = val;
        n.left = n.right = n.parent = null;
        n.color = Color.red;
        return n;
    }

    // Like `alloc`, but CONSTRUCTS the value in place from `args` — no temporary V
    // is built and copied. Backs the `emplace` API.
    private Node* allocEmplace(Args...)(K key, auto ref Args args) @nogc nothrow @trusted
    {
        import core.lifetime : emplace, forward;

        Node* n;
        if (freePool !is null) // reuse a recycled node — no malloc
        {
            n = freePool;
            freePool = n.parent;
        }
        else
            n = Allocator.instance.make!Node;
        n.key = key;
        emplace(&n.val, forward!args); // placement-construct V from args
        n.left = n.right = n.parent = null;
        n.color = Color.red;
        return n;
    }

    // Run a node's K/V destructors and keep its raw memory for reuse instead of
    // returning it to the OS — arm/disarm churn recycles nodes for free.
    private void recycle(Node* z) @nogc nothrow @trusted
    {
        destroy!false(*z); // frees a value's owned resources (e.g. a Vector's array)
        z.parent = freePool;
        freePool = z;
    }

    private void rotateLeft(Node* x) @nogc nothrow
    {
        auto y = x.right;
        x.right = y.left;
        if (y.left !is null)
            y.left.parent = x;
        y.parent = x.parent;
        if (x.parent is null)
            root = y;
        else if (x is x.parent.left)
            x.parent.left = y;
        else
            x.parent.right = y;
        y.left = x;
        x.parent = y;
    }

    private void rotateRight(Node* x) @nogc nothrow
    {
        auto y = x.left;
        x.left = y.right;
        if (y.right !is null)
            y.right.parent = x;
        y.parent = x.parent;
        if (x.parent is null)
            root = y;
        else if (x is x.parent.right)
            x.parent.right = y;
        else
            x.parent.left = y;
        y.right = x;
        x.parent = y;
    }

    /// Insert or overwrite the value for `key`.
    void set(K key, V val) @nogc nothrow @trusted
    {
        Node* parent = null;
        int lastCmp = 0;
        auto cur = root;
        while (cur !is null)
        {
            immutable c = cmpKey(key, cur.key);
            if (c == 0)
            {
                cur.val = val; // overwrite
                return;
            }
            parent = cur;
            lastCmp = c;
            cur = c < 0 ? cur.left : cur.right;
        }
        auto n = alloc(key, val);
        n.parent = parent;
        if (parent is null)
            root = n;
        else if (lastCmp < 0) // reuse the compare the loop already did
            parent.left = n;
        else
            parent.right = n;
        count++;
        if (parent is null || (parent is _min && lastCmp < 0))
            _min = n; // new leftmost iff inserted under the old min's (null) left
        insertFixup(n);
    }

    private void insertFixup(Node* z) @nogc nothrow
    {
        while (z.parent !is null && z.parent.color == Color.red)
        {
            auto gp = z.parent.parent;
            if (z.parent is gp.left)
            {
                auto y = gp.right; // uncle
                if (y !is null && y.color == Color.red)
                {
                    z.parent.color = Color.black;
                    y.color = Color.black;
                    gp.color = Color.red;
                    z = gp;
                }
                else
                {
                    if (z is z.parent.right)
                    {
                        z = z.parent;
                        rotateLeft(z);
                    }
                    z.parent.color = Color.black;
                    gp.color = Color.red;
                    rotateRight(gp);
                }
            }
            else
            {
                auto y = gp.left; // uncle
                if (y !is null && y.color == Color.red)
                {
                    z.parent.color = Color.black;
                    y.color = Color.black;
                    gp.color = Color.red;
                    z = gp;
                }
                else
                {
                    if (z is z.parent.left)
                    {
                        z = z.parent;
                        rotateRight(z);
                    }
                    z.parent.color = Color.black;
                    gp.color = Color.red;
                    rotateLeft(gp);
                }
            }
        }
        root.color = Color.black;
    }

    /// Pointer to the stored value, or null if absent.
    V* get(K key) @nogc nothrow return
    {
        auto n = find(key);
        return n is null ? null : &n.val;
    }

    /// Pointer to `key`'s value, inserting `val` first if the key is absent
    /// (existing values are kept). One descent — no separate get-after-set.
    V* getOrPut(K key, V val) @nogc nothrow @trusted return
    {
        Node* parent = null;
        int lastCmp = 0;
        auto cur = root;
        while (cur !is null)
        {
            prefetchR(cur.left);
            prefetchR(cur.right);
            immutable c = cmpKey(key, cur.key);
            if (c == 0)
                return &cur.val; // already present: keep it
            parent = cur;
            lastCmp = c;
            cur = c < 0 ? cur.left : cur.right;
        }
        auto n = alloc(key, val);
        n.parent = parent;
        if (parent is null)
            root = n;
        else if (lastCmp < 0)
            parent.left = n;
        else
            parent.right = n;
        count++;
        if (parent is null || (parent is _min && lastCmp < 0))
            _min = n; // new leftmost iff inserted under the old min's (null) left
        insertFixup(n);
        return &n.val;
    }

    /// Insert `key` CONSTRUCTING its value in place from `args` — no temporary V is
    /// materialised and copied (the eponymous operation this package was missing).
    /// If `key` already exists its value is kept and `args` ignored, like getOrPut;
    /// returns a pointer to the value either way. `emplace(key)` (no args) default-
    /// constructs the value.
    V* emplace(Args...)(K key, auto ref Args args) @nogc nothrow @trusted return
    {
        import core.lifetime : forward;

        Node* parent = null;
        int lastCmp = 0;
        auto cur = root;
        while (cur !is null)
        {
            prefetchR(cur.left);
            prefetchR(cur.right);
            immutable c = cmpKey(key, cur.key);
            if (c == 0)
                return &cur.val; // already present: keep it, ignore args
            parent = cur;
            lastCmp = c;
            cur = c < 0 ? cur.left : cur.right;
        }
        auto n = allocEmplace(key, forward!args);
        n.parent = parent;
        if (parent is null)
            root = n;
        else if (lastCmp < 0)
            parent.left = n;
        else
            parent.right = n;
        count++;
        if (parent is null || (parent is _min && lastCmp < 0))
            _min = n; // new leftmost iff inserted under the old min's (null) left
        insertFixup(n);
        return &n.val;
    }

    private Node* find(K key) @nogc nothrow
    {
        auto cur = root;
        while (cur !is null)
        {
            prefetchR(cur.left);
            prefetchR(cur.right);
            immutable c = cmpKey(key, cur.key);
            if (c == 0)
                return cur;
            cur = c < 0 ? cur.left : cur.right;
        }
        return null;
    }

    bool contains(K key) @nogc nothrow
    {
        return find(key) !is null;
    }

    // --- bound queries: one O(log n) descent, no second index / double search.
    // leftBound  = ceiling: the smallest key >= `key` (left edge of a range
    //              starting at `key`), i.e. tree.find_left(key).
    // rightBound = floor:   the largest key <= `key` (right edge of a range
    //              ending at `key`), i.e. tree.find_right(key).

    private Node* ceilNode(K key) @nogc nothrow
    {
        Node* best = null;
        auto cur = root;
        while (cur !is null)
        {
            immutable c = cmpKey(key, cur.key);
            if (c == 0)
                return cur;
            if (c < 0)
            {
                best = cur; // cur.key > key: candidate, look for a smaller one
                cur = cur.left;
            }
            else
                cur = cur.right;
        }
        return best;
    }

    private Node* floorNode(K key) @nogc nothrow
    {
        Node* best = null;
        auto cur = root;
        while (cur !is null)
        {
            immutable c = cmpKey(key, cur.key);
            if (c == 0)
                return cur;
            if (c > 0)
            {
                best = cur; // cur.key < key: candidate, look for a larger one
                cur = cur.right;
            }
            else
                cur = cur.left;
        }
        return best;
    }

    /// Ceiling. Value of the smallest key >= `key`, its key via `foundKey`;
    /// null when every key is smaller.
    V* leftBound(K key, out K foundKey) @nogc nothrow return
    {
        auto n = ceilNode(key);
        if (n is null)
            return null;
        foundKey = n.key;
        return &n.val;
    }

    /// Floor. Value of the largest key <= `key`, its key via `foundKey`;
    /// null when every key is larger.
    V* rightBound(K key, out K foundKey) @nogc nothrow return
    {
        auto n = floorNode(key);
        if (n is null)
            return null;
        foundKey = n.key;
        return &n.val;
    }

    private Node* upperNode(K key) @nogc nothrow
    {
        Node* best = null;
        auto cur = root;
        while (cur !is null)
        {
            if (cmpKey(key, cur.key) < 0) // cur.key > key: candidate, look left for a smaller one
            {
                best = cur;
                cur = cur.left;
            }
            else // cur.key <= key: everything here is too small, go right
                cur = cur.right;
        }
        return best;
    }

    /// Strict ceiling — `std::upper_bound` / Python `bisect_right`: value of the
    /// smallest key **strictly greater** than `key`, its key via `foundKey`;
    /// null when no key is greater. Everything to its left is the range `<= key`,
    /// so `foreachRange(min, key)` drains exactly that prefix.
    V* upperBound(K key, out K foundKey) @nogc nothrow return
    {
        auto n = upperNode(key);
        if (n is null)
            return null;
        foundKey = n.key;
        return &n.val;
    }

    /// In-order iteration restricted to keys in [lo, hi] (inclusive). Descends
    /// to the left bound then walks forward, so it costs O(log n + hits), not a
    /// full traversal.
    int foreachRange(K lo, K hi, scope int delegate(ref K, ref V) @nogc nothrow dg) @nogc nothrow
    {
        return walkRange(root, lo, hi, dg);
    }

    private static int walkRange(Node* n, K lo, K hi,
            scope int delegate(ref K, ref V) @nogc nothrow dg) @nogc nothrow
    {
        if (n is null)
            return 0;
        immutable cl = cmpKey(n.key, lo);
        immutable ch = cmpKey(n.key, hi);
        if (cl > 0) // n.key > lo: left subtree may still be in range
            if (auto r = walkRange(n.left, lo, hi, dg))
                return r;
        if (cl >= 0 && ch <= 0) // lo <= n.key <= hi
            if (auto r = dg(n.key, n.val))
                return r;
        if (ch < 0) // n.key < hi: right subtree may still be in range
            if (auto r = walkRange(n.right, lo, hi, dg))
                return r;
        return 0;
    }

    private void transplant(Node* u, Node* v) @nogc nothrow
    {
        if (u.parent is null)
            root = v;
        else if (u is u.parent.left)
            u.parent.left = v;
        else
            u.parent.right = v;
        if (v !is null)
            v.parent = u.parent;
    }

    private static Node* minimum(Node* n) @nogc nothrow
    {
        while (n.left !is null)
            n = n.left;
        return n;
    }

    // In-order successor of a node already in the tree (null past the max). Used
    // by the consuming range to advance without re-descending from the root.
    private static Node* successor(Node* n) @nogc nothrow
    {
        if (n.right !is null)
            return minimum(n.right);
        auto p = n.parent;
        while (p !is null && n is p.right)
        {
            n = p;
            p = p.parent;
        }
        return p;
    }

    /// Remove `key` if present; returns true when a node was removed.
    bool remove(K key) @nogc nothrow @trusted
    {
        auto z = find(key);
        if (z is null)
            return false;
        removeNode(z);
        return true;
    }

    // Remove a node we ALREADY hold — skips the O(log n) redundant find(). The
    // consuming range drains via this, turning popFront from two descents (a
    // re-find + a minimum(root)) into O(1) amortised per node.
    private void removeNode(Node* z) @nogc nothrow @trusted
    {
        // Advance the cached min BEFORE the structural edit: the leftmost has no
        // left child, so its successor is the next-smallest and stays valid.
        if (z is _min)
            _min = successor(z);
        Node* y = z;
        Color yColor = y.color;
        Node* x, xParent;
        if (z.left is null)
        {
            x = z.right;
            xParent = z.parent;
            transplant(z, z.right);
        }
        else if (z.right is null)
        {
            x = z.left;
            xParent = z.parent;
            transplant(z, z.left);
        }
        else
        {
            y = minimum(z.right);
            yColor = y.color;
            x = y.right;
            if (y.parent is z)
                xParent = y;
            else
            {
                xParent = y.parent;
                transplant(y, y.right);
                y.right = z.right;
                y.right.parent = y;
            }
            transplant(z, y);
            y.left = z.left;
            y.left.parent = y;
            y.color = z.color;
        }
        if (yColor == Color.black)
            deleteFixup(x, xParent);
        recycle(z); // keep the node memory for the next insert
        count--;
    }

    /// A consuming range over every entry with key <= `hi` (the `bisect_right`
    /// prefix, ascending). Each entry is removed from the map as you advance past
    /// it, so `foreach`, `.map`, `.each`, etc. drain and delete the prefix in one
    /// pass. The value is live while it is `front`; `popFront` disposes it.
    static struct RemoveRange
    {
        private Map* _map;
        private K _hi;
        private Node* _cur;

        private this(Map* map, K hi) @nogc nothrow
        {
            _map = map;
            _hi = hi;
            seek();
        }

        private void seek() @nogc nothrow
        {
            // O(1) via the cached leftmost; thereafter we advance by in-order
            // successor (no re-descent from the root).
            _cur = _map._min;
            if (_cur !is null && cmpKey(_cur.key, _hi) > 0)
                _cur = null; // smallest key is past hi: range exhausted
        }

        @property bool empty() const @nogc nothrow
        {
            return _cur is null;
        }

        @property Entry front() @nogc nothrow
        {
            return Entry(_cur);
        }

        void popFront() @nogc nothrow @trusted
        {
            // `_cur` is the current minimum (no left child), so its successor is
            // valid and stable across the rebalance below. Compute it FIRST, then
            // remove `_cur` by pointer (no re-find), then step — O(1) amortised.
            Node* nxt = successor(_cur);
            _map.removeNode(_cur);
            _cur = (nxt !is null && cmpKey(nxt.key, _hi) <= 0) ? nxt : null;
        }
    }

    /// Remove every entry with key <= `hi`; see `RemoveRange`.
    RemoveRange removeRight(K hi) @nogc nothrow return
    {
        return RemoveRange(&this, hi);
    }

    private static bool isBlack(Node* n) @nogc nothrow
    {
        return n is null || n.color == Color.black; // null leaves are black
    }

    private void deleteFixup(Node* x, Node* parent) @nogc nothrow
    {
        while (x !is root && isBlack(x))
        {
            if (x is parent.left)
            {
                auto w = parent.right; // sibling (non-null: black-height >= 1)
                if (w.color == Color.red)
                {
                    w.color = Color.black;
                    parent.color = Color.red;
                    rotateLeft(parent);
                    w = parent.right;
                }
                if (isBlack(w.left) && isBlack(w.right))
                {
                    w.color = Color.red;
                    x = parent;
                    parent = x.parent;
                }
                else
                {
                    if (isBlack(w.right))
                    {
                        if (w.left !is null)
                            w.left.color = Color.black;
                        w.color = Color.red;
                        rotateRight(w);
                        w = parent.right;
                    }
                    w.color = parent.color;
                    parent.color = Color.black;
                    if (w.right !is null)
                        w.right.color = Color.black;
                    rotateLeft(parent);
                    x = root;
                    parent = null;
                }
            }
            else
            {
                auto w = parent.left; // mirror image
                if (w.color == Color.red)
                {
                    w.color = Color.black;
                    parent.color = Color.red;
                    rotateRight(parent);
                    w = parent.left;
                }
                if (isBlack(w.right) && isBlack(w.left))
                {
                    w.color = Color.red;
                    x = parent;
                    parent = x.parent;
                }
                else
                {
                    if (isBlack(w.left))
                    {
                        if (w.right !is null)
                            w.right.color = Color.black;
                        w.color = Color.red;
                        rotateLeft(w);
                        w = parent.left;
                    }
                    w.color = parent.color;
                    parent.color = Color.black;
                    if (w.left !is null)
                        w.left.color = Color.black;
                    rotateRight(parent);
                    x = root;
                    parent = null;
                }
            }
        }
        if (x !is null)
            x.color = Color.black;
    }

    /// In-order (ascending key) iteration.
    int opApply(scope int delegate(ref K, ref V) @nogc nothrow dg) @nogc nothrow
    {
        return walk(root, dg);
    }

    private static int walk(Node* n, scope int delegate(ref K, ref V) @nogc nothrow dg) @nogc nothrow
    {
        if (n is null)
            return 0;
        if (auto r = walk(n.left, dg))
            return r;
        if (auto r = dg(n.key, n.val))
            return r;
        return walk(n.right, dg);
    }

    // --- range interface. D is range-oriented, so the tree is also a lazy,
    // allocation-free forward range: in-order (ascending key) traversal driven
    // by the nodes' parent pointers — no stack, no heap. Compose it with
    // std.range / std.algorithm, or `foreach (e; map[]) { if (...) break; }`.

    private static Node* leftmost(Node* n) @nogc nothrow
    {
        if (n is null)
            return null;
        while (n.left !is null)
            n = n.left;
        return n;
    }

    private static Node* succ(Node* n) @nogc nothrow
    {
        if (n.right !is null)
            return leftmost(n.right);
        auto p = n.parent;
        while (p !is null && n is p.right) // climb until we ascend from a left child
        {
            n = p;
            p = p.parent;
        }
        return p;
    }

    /// One entry of the range: the key by value, the value by reference.
    static struct Entry
    {
        private Node* _n;
        @property K key() const @nogc nothrow
        {
            return _n.key;
        }

        @property ref V value() @nogc nothrow
        {
            return _n.val;
        }
    }

    struct Range
    {
        private Node* _cur;
        @property bool empty() const @nogc nothrow
        {
            return _cur is null;
        }

        @property Entry front() @nogc nothrow
        {
            return Entry(_cur);
        }

        void popFront() @nogc nothrow
        {
            _cur = succ(_cur);
        }

        @property Range save() @nogc nothrow
        {
            return this;
        }
    }

    /// Forward range over every entry, ascending by key.
    Range opSlice() @nogc nothrow
    {
        return Range(leftmost(root));
    }

    /// Free every node. Empty afterwards.
    void clear() @nogc nothrow @trusted
    {
        freeSubtree(root);
        root = null;
        count = 0;
        _min = null;
        while (freePool !is null) // return recycled node memory to the OS
        {
            auto n = freePool;
            freePool = n.parent;
            Allocator.instance.deallocate((cast(void*) n)[0 .. Node.sizeof]);
        }
    }

    /// Reset AND reclaim. For this node-based tree there is no contiguous backing
    /// to keep, so `clear()` already returns every node (and the recycle pool) to
    /// the allocator — `clearShrink()` is provided for API parity with the other
    /// containers and coincides with `clear()`.
    void clearShrink() @nogc nothrow @trusted
    {
        clear();
    }

    private static void freeSubtree(Node* n) @nogc nothrow @trusted
    {
        if (n is null)
            return;
        freeSubtree(n.left);
        freeSubtree(n.right);
        Allocator.instance.dispose(n);
    }
}

/// The valueless companion: an ordered set on the same red-black tree.
struct OrderedSet(T, Allocator = Mallocator)
{
    private struct Unit
    {
    }

    private Map!(T, Unit, Allocator) tree;

    // Copyability follows the underlying tree: copyable when `T` is (deep clone),
    // move-only when `T` is (the compiler-generated copy hook forwards to `tree`).

    void add(T item) @nogc nothrow
    {
        tree.set(item, Unit.init);
    }

    bool remove(T item) @nogc nothrow
    {
        return tree.remove(item);
    }

    bool has(T item) @nogc nothrow
    {
        return tree.contains(item);
    }

    bool opBinaryRight(string op : "in")(T item) @nogc nothrow
    {
        return has(item);
    }

    @property size_t length() const @nogc nothrow
    {
        return tree.length;
    }

    @property bool empty() const @nogc nothrow
    {
        return tree.empty;
    }

    void clear() @nogc nothrow
    {
        tree.clear();
    }

    /// Reset AND reclaim (see Map.clearShrink; coincides with clear() here).
    void clearShrink() @nogc nothrow
    {
        tree.clearShrink();
    }

    /// Iterate members in ascending order.
    int opApply(scope int delegate(ref T) @nogc nothrow dg) @nogc nothrow
    {
        return tree.opApply((ref T k, ref Unit _) => dg(k));
    }

    OrderedSet dup() @nogc nothrow
    {
        OrderedSet r;
        foreach (ref k, ref _; tree)
            r.add(k);
        return r;
    }

    OrderedSet union_(ref OrderedSet other) @nogc nothrow
    {
        OrderedSet r;
        foreach (ref k, ref _; tree)
            r.add(k);
        foreach (item; other)
            r.add(item);
        return r;
    }

    OrderedSet intersection(ref OrderedSet other) @nogc nothrow
    {
        OrderedSet r;
        foreach (item; this)
            if (other.has(item))
                r.add(item);
        return r;
    }

    OrderedSet difference(ref OrderedSet other) @nogc nothrow
    {
        OrderedSet r;
        foreach (item; this)
            if (!other.has(item))
                r.add(item);
        return r;
    }

    OrderedSet symmetricDifference(ref OrderedSet other) @nogc nothrow
    {
        OrderedSet r;
        foreach (item; this)
            if (!other.has(item))
                r.add(item);
        foreach (item; other)
            if (!has(item))
                r.add(item);
        return r;
    }

    OrderedSet opBinary(string op : "+")(ref OrderedSet other) @nogc nothrow
    {
        return union_(other);
    }

    OrderedSet opBinary(string op : "-")(ref OrderedSet other) @nogc nothrow
    {
        return difference(other);
    }

    bool isSubsetOf(ref OrderedSet other) @nogc nothrow
    {
        foreach (item; this)
            if (!other.has(item))
                return false;
        return true;
    }

    bool isSupersetOf(ref OrderedSet other) @nogc nothrow
    {
        return other.isSubsetOf(this);
    }

    bool equals(ref OrderedSet other) @nogc nothrow
    {
        return length == other.length && isSubsetOf(other);
    }
}

@nogc nothrow unittest // ordered map: balanced insert, lookup, sorted iteration
{
    Map!(const(char)[], int) m;
    m.set("banana", 2);
    m.set("apple", 1);
    m.set("cherry", 3);
    m.set("apple", 10); // overwrite, no new node
    assert(m.length == 3);
    assert(*m.get("apple") == 10);
    assert(m.get("durian") is null);
    assert(m.contains("banana") && !m.contains("durian"));

    const(char)[][3] seen;
    size_t n = 0;
    foreach (ref k, ref v; m)
        seen[n++] = k;
    assert(seen[0] == "apple" && seen[1] == "banana" && seen[2] == "cherry");
}

@nogc nothrow unittest // stays balanced/correct across ascending inserts (BST worst case)
{
    Map!(int, int) m;
    foreach (i; 0 .. 1000)
        m.set(i, i * i);
    assert(m.length == 1000);
    foreach (i; 0 .. 1000)
        assert(*m.get(i) == i * i);

    long prev = -1;
    bool sorted = true;
    foreach (ref k, ref v; m)
    {
        if (k <= prev)
            sorted = false;
        prev = k;
    }
    assert(sorted);
}

@nogc nothrow unittest // RB deletion: membership and ordering hold after removals
{
    Map!(int, int) m;
    foreach (i; 0 .. 500)
        m.set(i, i);
    // remove all evens
    foreach (i; 0 .. 500)
        if (i % 2 == 0)
            assert(m.remove(i));
    assert(m.length == 250);
    assert(!m.remove(0)); // already gone
    foreach (i; 0 .. 500)
    {
        if (i % 2 == 0)
            assert(m.get(i) is null);
        else
            assert(*m.get(i) == i);
    }
    // still sorted after all the rebalancing
    long prev = -1;
    bool sorted = true;
    foreach (ref k, ref v; m)
    {
        if (k <= prev)
            sorted = false;
        prev = k;
    }
    assert(sorted);
}

@nogc nothrow unittest // pseudo-random insert/delete churn stays consistent
{
    Map!(int, int) m;
    bool[256] present;
    uint seed = 0x1234_5678;
    foreach (_; 0 .. 20_000)
    {
        seed = seed * 1_664_525 + 1_013_904_223; // LCG (no Math.random in scripts/tests)
        immutable key = seed % 256;
        if ((seed >> 16) & 1)
        {
            m.set(key, cast(int) key);
            present[key] = true;
        }
        else
        {
            immutable had = present[key];
            assert(m.remove(key) == had);
            present[key] = false;
        }
    }
    size_t expect = 0;
    foreach (p; present)
        if (p)
            expect++;
    assert(m.length == expect);
    foreach (k; 0 .. 256)
        assert((m.get(k) !is null) == present[k]);
}

@nogc nothrow unittest // leftBound (ceiling) / rightBound (floor) / range
{
    Map!(const(char)[], int) m; // keys: a c e g
    foreach (i, k; ["a", "c", "e", "g"])
        m.set(k, cast(int) i);

    const(char)[] fk;
    // exact hit resolves to itself for both bounds
    assert(*m.leftBound("c", fk) == 1 && fk == "c");
    assert(*m.rightBound("c", fk) == 1 && fk == "c");
    // between keys: ceiling rounds up, floor rounds down
    assert(*m.leftBound("b", fk) == 1 && fk == "c"); // smallest >= "b"
    assert(*m.rightBound("d", fk) == 1 && fk == "c"); // largest <= "d"
    // edges
    assert(*m.leftBound("g", fk) == 3 && fk == "g");
    assert(m.leftBound("h", fk) is null); // nothing >= "h"
    assert(m.rightBound("Z", fk) is null); // nothing <= "Z" (uppercase sorts first)
    assert(*m.rightBound("z", fk) == 3 && fk == "g"); // floor past the end

    // upperBound (bisect_right): smallest key strictly greater than the arg
    assert(*m.upperBound("c", fk) == 2 && fk == "e"); // exact hit skips to the next
    assert(*m.upperBound("b", fk) == 1 && fk == "c"); // between keys
    assert(*m.upperBound("Z", fk) == 0 && fk == "a"); // before everything
    assert(m.upperBound("g", fk) is null); // nothing greater than the max

    // foreachRange [b, f] -> c, e (O(log n + hits), not a full walk)
    const(char)[][8] hit;
    size_t n = 0;
    m.foreachRange("b", "f", (ref k, ref v) { hit[n++] = k; return 0; });
    assert(n == 2 && hit[0] == "c" && hit[1] == "e");
}

@nogc nothrow unittest // getOrPut: insert-once + return live pointer; node recycling
{
    Map!(int, int) m;
    assert(*m.getOrPut(5, 100) == 100); // inserted
    assert(*m.getOrPut(5, 999) == 100); // present: kept, not overwritten
    *m.getOrPut(5, 0) += 1; // mutate in place through the returned pointer
    assert(*m.get(5) == 101 && m.length == 1);

    // remove drains nodes into the free pool; re-inserting reuses that memory
    foreach (i; 0 .. 200)
        m.set(i, i);
    foreach (i; 0 .. 200)
        assert(m.remove(i));
    assert(m.empty);
    foreach (i; 0 .. 200)
        m.set(i, i * 2); // served from the recycle pool, not fresh malloc
    assert(m.length == 200 && *m.get(150) == 300);
}

@nogc nothrow unittest // emplace: constructs the value IN PLACE — no copy/move of V
{
    static struct Counted
    {
        int x;
        static int copies;
        this(int v) @nogc nothrow
        {
            x = v;
        }

        this(this) @nogc nothrow
        {
            ++copies;
        }
    }

    Counted.copies = 0;
    Map!(int, Counted) m;
    auto p = m.emplace(7, 42); // Counted(42) built directly in the node
    assert(p.x == 42 && m.length == 1);
    assert(Counted.copies == 0, "emplace must not copy/move the value");

    // existing key: value kept, args ignored, still no copy
    assert(m.emplace(7, 999).x == 42);
    assert(Counted.copies == 0);

    // emplace(key) with no args default-constructs
    Map!(int, Counted) d;
    assert(d.emplace(1).x == 0 && d.length == 1);
}

@nogc nothrow unittest // removeRight: consuming range drains the <= hi prefix in order
{
    Map!(int, int) m;
    foreach (i; 0 .. 10)
        m.set(i, i * 10);

    int n = 0, sum = 0, lastKey = -1;
    bool ordered = true;
    foreach (e; m.removeRight(4)) // keys 0,1,2,3,4
    {
        if (e.key <= lastKey)
            ordered = false;
        lastKey = e.key;
        sum += e.value;
        n++;
    }
    assert(n == 5 && ordered && sum == 100); // 0+10+20+30+40
    assert(m.length == 5); // 5..9 survive
    foreach (i; 0 .. 5)
        assert(m.get(i) is null);
    foreach (i; 5 .. 10)
        assert(*m.get(i) == i * 10);

    foreach (e; m.removeRight(1000)) // past the max: drains everything
    {
    }
    assert(m.empty);
}

@nogc nothrow unittest // OrderedSet: membership, in, dedup, ordered iteration
{
    OrderedSet!int s;
    s.add(22);
    s.add(1);
    s.add(22); // dedup
    s.add(3);
    assert(s.length == 3);
    assert(1 in s && !(9 in s));
    assert(s.remove(22) && !s.has(22));
    assert(s.length == 2);

    int[2] seen;
    size_t n = 0;
    foreach (v; s)
        seen[n++] = v;
    assert(seen[0] == 1 && seen[1] == 3); // sorted
}

@nogc nothrow unittest // OrderedSet algebra
{
    OrderedSet!int a, b;
    foreach (v; [1, 2, 3, 4])
        a.add(v);
    foreach (v; [3, 4, 5, 6])
        b.add(v);

    auto u = a.union_(b);
    assert(u.length == 6); // 1..6
    auto i = a.intersection(b);
    assert(i.length == 2 && i.has(3) && i.has(4));
    auto d = a.difference(b);
    assert(d.length == 2 && d.has(1) && d.has(2) && !d.has(3));
    auto sd = a.symmetricDifference(b);
    assert(sd.length == 4 && sd.has(1) && sd.has(6) && !sd.has(3));

    OrderedSet!int sub;
    sub.add(1);
    sub.add(2);
    assert(sub.isSubsetOf(a) && a.isSupersetOf(sub));
    assert(!a.isSubsetOf(sub));
}

@nogc nothrow unittest // Map is copyable (deep clone, like std::map) — independent
{
    Map!(int, int) a;
    foreach (i; 0 .. 20)
        a.set(i, i * 10);
    auto b = a; // this(this): deep clone of the tree
    assert(b.length == 20);
    b.set(5, 999); // mutating the copy must not touch the original
    assert(*a.get(5) == 50 && *b.get(5) == 999);
    a.remove(7); // and vice versa
    assert(a.get(7) is null && *b.get(7) == 70);
    // both iterate their own full contents in order
    int n;
    foreach (k, v; b)
        n++;
    assert(n == 20);
}


emplace
=======

**C++-grade, GC-free data structures and smart pointers for D.**

Writing ``@nogc`` D today usually means falling back to C-isms — raw pointers,
manual ``malloc``/``free``, hand-rolled containers. ``emplace`` closes that gap:
the containers and smart pointers you expect from C++'s ``<memory>`` /
``<vector>`` / ``<map>``, allocator-aware (Alexandrescu's
``std.experimental.allocator``), ``@nogc`` when the allocator is, and correct on
current LDC/DMD.

.. contents::
   :local:

Install
-------

.. code-block:: sh

   dub add emplace

Smart pointers
--------------

``emplace.smartptr`` — modeled on libc++'s ``<memory>``, parameterized on an
allocator (``Mallocator`` by default).

``Uniq!(T, Alloc)`` — unique_ptr
   Single ownership, move-only. A bitwise copy would double-free, so the type is
   move-only; the compiler moves it, leaving the source null (its destructor a
   no-op).

   * ``Uniq!T.make(args)`` — allocate + construct in place.
   * ``get`` / ``borrow`` — a reference to the owned value.
   * ``take()`` — Rust ``Option::take``: move ownership out into the returned
     ``Uniq``, leaving ``this`` null.
   * ``intoInner()`` — Rust ``Box::into_inner``: move the value out by value and
     free the box.

``Shared!(T, Alloc)`` — shared_ptr
   Reference counted and copyable (copy bumps the strong count, the last owner
   frees). Like ``make_shared`` the value lives inline in the control block, so a
   shared object is a single allocation; the block also carries a weak count.
   Counts are non-atomic (single-thread model).

   * ``Shared!T.make(args)`` — construct.
   * ``get`` — the owned value. ``useCount`` — strong owners.
   * ``weaken()`` — a ``Weak`` observer.

``Weak!(T, Alloc)`` — weak_ptr
   A non-owning observer. Keeps the control block alive (to answer "is it still
   there?") but not the value.

   * ``lock()`` — promote to a ``Shared`` if the object is alive, else empty.
   * ``expired`` — whether the object has been destroyed.

Containers
----------

``Vector!(T, Alloc)`` (``emplace.vector``)
   A dynamic array. Bulk ``put(slice)`` is a single ``memcpy`` (not a per-element
   loop).

   API: ``put(x)`` / ``put(slice)``, ``popBack``, ``clear`` (keeps capacity),
   ``length`` (get/set), ``reserve``, ``shrinkToFit`` (``shrink_to_fit`` — gives
   excess capacity back), ``opSlice`` (``v[]``), ``opIndex``.

   ``Vector!bool`` is a **bit-packed specialization** (like ``std::vector<bool>``):
   one bit per element in a ``size_t`` word array, and ``opIndex`` returns an
   assignable, bool-convertible proxy bit-reference.

``Deque!(T, Alloc)`` (``emplace.deque``)
   A double-ended queue: a circular buffer over one contiguous grow-by-doubling
   block (power-of-two capacity + mask). O(1) ``pushFront`` / ``pushBack`` /
   ``popFront`` / ``popBack`` and O(1) ``opIndex`` random access.

   **Releases memory as it drains** (halves capacity once load drops to ¼, with
   hysteresis; frees the block entirely at empty), so a long-running queue never
   grows without bound. API: ``pushFront`` / ``pushBack`` / ``popFront`` /
   ``popBack``, ``front`` / ``back`` / ``opIndex``, ``length`` / ``empty`` /
   ``clear``, ``opSlice`` (forward range).

``Map!(K, V)`` (``emplace.map``)
   An ordered map on a hand-rolled red-black tree: O(log n) ``set`` / ``get`` /
   ``remove``, in-order (sorted) iteration. Copyable (deep clone of the tree,
   like ``std::map``) when both key and value are.

   Bound queries (no second index, one descent):

   * ``leftBound(key)`` — ceiling, the smallest key ``>= key``.
   * ``rightBound(key)`` — floor, the largest key ``<= key``.
   * ``upperBound(key)`` — strict ceiling (``bisect_right`` / ``upper_bound``).
   * ``foreachRange(lo, hi, dg)`` — O(log n + hits) range scan.
   * ``removeRight(hi)`` — a consuming range that drains the ``<= hi`` prefix.

``OrderedSet!T`` (``emplace.map``)
   The ordered set — the valueless companion: ``add`` / ``remove`` / ``in``, and
   set algebra (``union_`` / ``intersection`` / ``difference`` /
   ``symmetricDifference``, ``isSubsetOf`` / ``isSupersetOf``).

``HashMap!(K, V)`` (``emplace.hashmap``)
   ``unordered_map`` — open-addressed hash table, linear probing with
   backward-shift deletion (no tombstones), grows at 0.75 load.
   ``set`` / ``get`` / ``remove`` / ``contains`` / ``opApply`` / ``clear``.

``HashSet!K`` (``emplace.hashmap``)
   ``unordered_set`` — ``add`` / ``remove`` / ``in`` / ``opApply``.

RAII and smart-pointer safety
-----------------------------

Every container moves elements into place and releases each one on
``popBack`` / ``clear`` / ``~this`` (its ``.free()`` by convention, else its
destructor), so a ``Vector!(Uniq!T)`` or ``Deque!(Shared!T)`` never leaks. Each
container is copyable exactly when its element is — a deep, independent copy;
an element with a move-only type (e.g. ``Uniq``) makes the whole container
move-only, so a bitwise copy can never double-free.

Allocators
----------

Every type takes an ``std.experimental.allocator`` allocator, defaulting to
``Mallocator``. Attributes are inferred, so ``Mallocator`` gives a
``@nogc nothrow`` surface; ``GCAllocator``, ``FreeList``, ``Region``,
``InSituRegion`` and custom allocators plug in unchanged. A ``FreeList`` node
pool measured ~10-16x cheaper per allocation than ``malloc``.

Acknowledgements
----------------

``emplace`` is inspired by `automem <https://github.com/atilaneves/automem>`_ by
**Atila Neves**, which pioneered allocator-aware smart pointers and a vector for
D. ``emplace`` carries that idea forward with a wider container set, libc++/Rust
semantics, and fixes for issues on current compilers.

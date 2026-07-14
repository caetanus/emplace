# emplace

**C++-grade, GC-free data structures and smart pointers for D.**

Writing `@nogc` D today usually means falling back to C-isms — raw pointers,
manual `malloc`/`free`, hand-rolled containers. `emplace` closes that gap: the
containers and smart pointers you expect from C++'s `<memory>`/`<vector>`/`<map>`,
allocator-aware (Alexandrescu's `std.experimental.allocator`), `@nogc` when the
allocator is, and correct on current LDC/DMD.

## Install

```sh
dub add emplace
```

```d
import emplace.smartptr : Uniq, Shared, Weak;
import emplace.vector : Vector;
import emplace.map : Map, OrderedSet;
```

## What's in the box

### Smart pointers (`emplace.smartptr`) — modeled on libc++'s `<memory>`
- **`Uniq!(T, Alloc = Mallocator)`** — `unique_ptr`: single ownership, move-only,
  plus Rust-flavored `borrow` / `take` (`Option::take`) / `intoInner`
  (`Box::into_inner`).
- **`Shared!(T, Alloc = Mallocator)`** — `shared_ptr`: reference counted, copy
  bumps the count, `make_shared`-style inline control block (one allocation),
  with a weak count.
- **`Weak!(T, Alloc = Mallocator)`** — `weak_ptr`: non-owning observer,
  `lock()` / `expired`.

### Containers
- **`emplace.vector.Vector!(T, Alloc = Mallocator)`** — a dynamic array; bulk
  `put(slice)` is a single `memcpy` (not a per-element loop). `shrinkToFit`
  (`shrink_to_fit`). **`Vector!bool` is bit-packed** (`std::vector<bool>`): one
  bit per element, `opIndex` returns an assignable proxy bit-reference.
- **`emplace.deque.Deque!(T, Alloc = Mallocator)`** — a double-ended queue: a
  circular buffer over one contiguous block, O(1) push/pop at both ends and O(1)
  random access. **Releases memory as it drains** (halves capacity at ¼ load,
  frees at empty) — safe for long-running FIFOs.
- **`emplace.map.Map!(K, V)`** — an ordered map on a hand-rolled red-black tree
  (O(log n) insert/lookup/remove, sorted iteration, `leftBound`/`rightBound`
  floor/ceiling + `foreachRange`, `removeRight` consuming prefix range).
- **`emplace.map.OrderedSet!T`** — the ordered set: the valueless companion
  (union / intersection / difference / symmetric difference, subset / superset).
- **`emplace.hashmap.HashMap!(K, V)`** — `unordered_map`: open-addressed hash
  table, linear probing with backward-shift deletion (no tombstones).
- **`emplace.hashmap.HashSet!K`** — `unordered_set`.

Every container is **RAII and smart-pointer safe**: elements are *moved* into
place, and `popBack`/`clear`/`~this` release each one (its `.free()` or
destructor), so a `Vector!(Uniq!T)` or `Deque!(Shared!T)` never leaks. Each is
**copyable exactly when its element is** (a deep, independent copy — `Map` deep-
clones its tree like `std::map`); an element with a move-only type (e.g. `Uniq`)
makes the whole container move-only, so a bitwise copy can never double-free.
All expose D **ranges** (`opSlice`).

## Allocators

Everything is parameterized on an `std.experimental.allocator` allocator,
defaulting to `Mallocator`. Attributes are inferred, so with `Mallocator`
the whole surface is `@nogc nothrow`; plug `GCAllocator`, `FreeList`, `Region`,
`InSituRegion`, or your own — unchanged.

```d
import std.experimental.allocator.building_blocks.free_list : FreeList;
import std.experimental.allocator.mallocator : Mallocator;

// a node pool: ~10-16x cheaper per allocation than malloc in our benchmarks
alias Pool = FreeList!(Mallocator, 64);
```

## Example

```d
import emplace.smartptr : Uniq, Shared;
import emplace.vector : Vector;

@nogc nothrow:

auto box = Uniq!int.make(42);      // owns a heap int, freed on scope exit
int taken = box.intoInner();       // move the value out (Box::into_inner)

auto rc = Shared!string.make("hi");
auto rc2 = rc;                     // refcount == 2, freed when the last dies

Vector!ubyte buf;
buf.put(cast(const(ubyte)[]) "hello");  // one memcpy, no per-byte loop
```

## Acknowledgements

`emplace` was originally built for **[dreads](https://github.com/caetanus/dreads)**,
a GC-free Redis/Valkey-compatible database in D, whose data plane runs with the
collector disabled — so it needed exactly these containers without C-isms. It is
extracted here as a standalone, reusable package.

It is inspired by **[automem](https://github.com/atilaneves/automem)** by
**Atila Neves**, which pioneered allocator-aware smart pointers and a vector for
D. `emplace` carries that idea forward with a wider container set, libc++/Rust
semantics, and fixes for issues that surface on current compilers. Credit for the
original direction is his.

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Marcelo Aires Caetano.

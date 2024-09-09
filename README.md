### odin-gc - Odin Garbage Collector
#### Yawning Angel (yawning at schwanenlied dot me)

This is a proof-of-concept garbage collector for the [Odin][1] language
using the [Boehm-Demers-Weiser conservative C/C++ Garbage Collector][2].

It currently requires Linux, and a copy of [libgc][3], which is packaged
by most distributions.

#### Usage

```
import gc "path/to/odin-gc`

main :: proc() {
    context = gc.init_context()

    // Do useful things:
    //
    // - You *can* use `free` and `delete`, if you really want to, but
    //   why bother?  Embrace the lazy.
    // - Do NOT use:
    //   - `core:dynlib.load_library`, use `gc.load_library` instead.
    //   - `core:thread`
    // - Avoid:
    //   - `base:runtime/heap_allocator`
    //   - `core:mem/virtual`
}
```

#### Limitations

- It is a stop-the-world mark-and-sweep GC.
- `GC_init` is used instead of `GC_INIT`.
- `gc.load_library` must be used instead of `core:dynlib/load_library`
- `core:thread` may appear to work, but it likely is broken.

#### Future Improvements

- Add support for controlling GC behavior.
- Add an allocator for "atomic" memory.
- Add an allocator for "uncollectable" memory.
- Work on supporting the things that are broken.

[1]: https://odin-lang.org
[2]: https://www.hboehm.info/gc/
[3]: https://archlinux.org/packages/core/x86_64/gc/
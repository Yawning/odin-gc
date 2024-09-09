package odin_gc

import "base:runtime"
import "core:c"
import "core:mem"
import "core:sync"

// TODO: Someone that cares can deal with Windows/Darwin.
when ODIN_OS == .Linux {
	foreign import gc "system:gc"
} else {
	#panic("gc: not supported on this target")
}

#assert(mem.DEFAULT_ALIGNMENT == 2 * size_of(uintptr))

@(private)
GC_GRANULE_BYTES :: mem.DEFAULT_ALIGNMENT
@(private)
Init_Once: sync.Once

@(private)
Temp_Allocator_Once: sync.Once
@(private)
Temp_Allocator: mem.Mutex_Allocator
@(private)
Temp_Allocator_Impl: mem.Scratch_Allocator

@(private, default_calling_convention="c")
foreign gc {
	GC_init           :: proc() ---

	GC_enable         :: proc() ---
	GC_is_disabled    :: proc() -> c.int ---
	GC_disable        :: proc() ---

	GC_gcollect       :: proc() ---

	GC_malloc         :: proc(size: c.size_t) -> rawptr ---
	GC_malloc_atomic  :: proc(size: c.size_t) -> rawptr ---
	GC_memalign       :: proc(align, size: c.size_t) -> rawptr ---
	GC_realloc        :: proc(ptr: rawptr, size: c.size_t) -> rawptr ---
	GC_free           :: proc(ptr: rawptr) ---

	GC_noop1_ptr      :: proc(ptr: rawptr) ---

	GC_get_prof_stats :: proc(stats: ^Prof_Stats, size: c.size_t) -> c.size_t ---
}

// Garbage collector statistics.
Prof_Stats :: struct {
	// Heap size in bytes (including the area unmapped to OS).
	// Same as GC_get_heap_size() + GC_get_unmapped_bytes().
	heapsize_full: c.size_t,
	// Total bytes contained in free and unmapped blocks.
	// Same as GC_get_free_bytes() + GC_get_unmapped_bytes().
	free_bytes_full: c.size_t,
	// Amount of memory unmapped to OS.  Same as the value
	// returned by GC_get_unmapped_bytes().
	unmapped_bytes: c.size_t,
	// Number of bytes allocated since the recent collection.
	// Same as returned by GC_get_bytes_since_gc().
	bytes_allocd_since_gc: c.size_t,
	// Number of bytes allocated before the recent garbage
	// collection.  The value may wrap.  Same as the result of
	// GC_get_total_bytes() - GC_get_bytes_since_gc().
	allocd_bytes_before_gc: c.size_t,
	// Number of bytes not considered candidates for garbage
	// collection.  Same as returned by GC_get_non_gc_bytes().
	non_gc_bytes: c.size_t,
	// Garbage collection cycle number.  The value may wrap
	// (and could be -1).  Same as returned by GC_get_gc_no().
	gc_no: c.size_t,
	// Number of marker threads (excluding the initiating one).
	// Same as returned by GC_get_parallel (or 0 if the
	// collector is single-threaded).
	markers_m1: c.size_t,
	// Approximate number of reclaimed bytes after recent GC.
	bytes_reclaimed_since_gc: c.size_t,
	// Approximate number of bytes reclaimed before the recent
	// garbage collection.  The value may wrap.
	reclaimed_bytes_before_gc: c.size_t,
	// Number of bytes freed explicitly since the recent GC.
	// Same as returned by GC_get_expl_freed_bytes_since_gc().
	expl_freed_bytes_since_gc: c.size_t,
	// Total amount of memory obtained from OS, in bytes.
	obtained_from_os_bytes: c.size_t,
}

/*
Returns a context with the allocator and temp_allocator configured
to use the Boehm-Demers-Weiser conservative C/C++ Garbage Collector.
*/
@(require_results)
init_context :: proc() -> runtime.Context {
	context.allocator = allocator()

	sync.once_do(
		&Temp_Allocator_Once,
		proc() {
			mem.scratch_allocator_init(
				&Temp_Allocator_Impl,
				4 * mem.Megabyte,
			)
			mem.mutex_allocator_init(
				&Temp_Allocator,
				mem.scratch_allocator(&Temp_Allocator_Impl),
			)
		},
	)
	context.temp_allocator = mem.mutex_allocator(&Temp_Allocator)

	return context
}

/*
Returns an allocator backed by the Boehm-Demers-Weiser conservative
C/C++ Garbage Collector.  Every call returns the sane underlying
allocator.

WARNING: References to memory managed by the garbage collector that
reside in regions created by the os (eg: via mmap, malloc), will NOT
prevent the GC from freeing memory.  It is best NOT to mix and match
the default `base:runtime/heap_allocator`/`core:mem/virtual` with this
allocator.
*/
@(require_results)
allocator :: proc() -> mem.Allocator {
	sync.once_do(
		&Init_Once,
		proc() {
			// Ensure libgc is initialized.
			//
			// The documentation has a note that portable programs
			// should use the `GC_INIT` macro instead, but as far
			// as I can tell this only impacts Android.
			//
			// TODO: Possibly enable incremental mode.
			GC_init()
		},
	)
	return mem.Allocator{
		procedure = allocator_proc,
		data = nil,
	}
}

/*
Fills the provided `Prof_Stats` with garbage collector stats.

Unknown fields (due to different libgc versions) will be initialized
with `-1`.
*/
get_prof_stats :: proc(stats: ^Prof_Stats) {
	GC_get_prof_stats(stats, size_of(stats^))
}

@(private)
allocator_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr, old_size: int,
	loc := #caller_location) -> ([]byte, mem.Allocator_Error) {

	// Notes:
	// - libgc always returns zero-initialized memory when
	//   allocating, so there is no differece between `Zeroed`
	//   and `Non_Zeroed`.
	//
	// - "We always set GC_GRANULE_BYTES to twice the length of a
	//    pointer."
	//
	//   This matches Odin's `DEFAULT_ALIGNMENT`.  As the interface
	//   only allows powers of 2 for the alignment parameter,
	//   `GC_malloc` handles `alignment <= DEFAULT_ALIGNMENT`.

	assert(alignment == 0 || mem.is_power_of_two(uintptr(alignment)))

	@(require_results)
	raw_alloc :: proc(size, alignment: int) -> ([]byte, mem.Allocator_Error) {
		if size == 0 {
			return nil, nil
		}

		ptr: rawptr
		switch {
		case alignment <= GC_GRANULE_BYTES:
			ptr = GC_malloc(c.size_t(size))
		case:
			assert(mem.is_power_of_two(uintptr(alignment)))
			ptr = GC_memalign(c.size_t(alignment), c.size_t(size))
		}
		if ptr == c.NULL {
			return nil, .Out_Of_Memory
		}
		return mem.byte_slice(ptr, size), nil
	}

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return raw_alloc(size, alignment)
	case .Free:
		// Per the documentation:
		// "Probably a performance loss for very small objects (<= 8 bytes)".
		GC_free(old_memory)
	case .Free_All:
		return nil, .Mode_Not_Implemented
	case .Resize, .Resize_Non_Zeroed:
		if size == 0 {
			// `GC_realloc` does this for us, but it is not always
			// called.
			GC_free(old_memory)
			return nil, nil
		}
		if old_memory == nil {
			return raw_alloc(size, alignment)
		}
		if alignment <= GC_GRANULE_BYTES {
			// GC_realloc has no way of specifying alignment,
			// however we know that it will always align to
			// `GC_GRANULE_BYTES`.
			//
			// We do not care about the old alignment for
			// this case as the power of 2 invaruant ensures
			// that even if the pointer is reused, it will be
			// correct.
			ptr := GC_realloc(old_memory, c.size_t(size))
			if ptr == c.NULL {
				// It looks like `mem._default_resize_bytes_align`
				// leaves the old memory intact on failure.
				return nil, .Out_Of_Memory
			}
			return mem.byte_slice(ptr, size), nil
		}

		// Call the generic implementation in `core:mem`.
		return mem.default_resize_bytes_align(
			mem.byte_slice(old_memory, old_size),
			size,
			alignment,
			mem.Allocator{
				procedure = allocator_proc,
				data = allocator_data,
			},
		)
	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}

	return nil, nil
}

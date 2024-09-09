package odin_gc

import "core:c"
import "core:dynlib"
import "core:os"
import "core:strings"

foreign import gc "system:gc"

@(private, default_calling_convention="c")
foreign gc {
	GC_dlopen :: proc(filename: cstring, flags: c.int) -> rawptr ---
}

/*
Loads a dynamic library from the filesystem, in a way that is safe for
use with the garbage collector.  This *MUST* be used instead of the
`core:dynlib` routine if the program is multi-threaded.

See: `core:dynlib/load_library`
*/
load_library :: proc(
	path: string,
	global_symbols := false) -> (library: dynlib.Library, did_load: bool) {
	flags := os.RTLD_NOW
	if global_symbols {
		flags |= os.RTLD_GLOBAL
	}

	cstr := strings.clone_to_cstring(path)
	defer delete(cstr) // Could just leak this since we have a GC.
	handle := GC_dlopen(cstr, c.int(flags))

	return dynlib.Library(handle), handle != nil
}

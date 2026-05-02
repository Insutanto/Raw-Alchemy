// Legacy umbrella header kept for reference only.
// The CLibRaw module.modulemap now references "libraw.h" directly via the
// pkg-config include path (-I/usr/include/libraw on Linux, brew equivalent
// on macOS) rather than through this wrapper.
//
// This file is no longer used by the module map but is kept here to document
// the libraw dependency and for IDE convenience.

#ifndef CLIBRAW_H
#define CLIBRAW_H

#include <libraw/libraw.h>

#endif /* CLIBRAW_H */

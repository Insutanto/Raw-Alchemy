// Umbrella header for the CLibRaw SPM system-library target.
// This file is placed in Sources/CLibRaw/include/ so that SPM adds this
// directory to the compiler's header-search paths, satisfying the
// module.modulemap declaration above.
//
// It simply re-exports the main libraw header which is located by the
// pkg-config flags supplied in Package.swift.

#ifndef CLIBRAW_H
#define CLIBRAW_H

#include <libraw/libraw.h>

#endif /* CLIBRAW_H */

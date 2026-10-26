// nanosvg is a single-header library whose implementation may only be compiled
// into one translation unit. The implementation lives in libslic3r rather than
// in the GUI because libslic3r's NSVGUtils wrapper parses SVG files and every
// consumer of libslic3r has to resolve those symbols.
//
// nanosvg.h guards the implementation with the same include guard as its
// declarations, so this file must include it before anything else in the
// translation unit does. It is kept out of the unity build for that reason.
#define NANOSVG_IMPLEMENTATION
#include <nanosvg/nanosvg.h>

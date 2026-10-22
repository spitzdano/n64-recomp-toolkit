// Code called from the [[patches.hook]] entries in __TAG__.toml, and C replacements for the functions its `ignored`
// list skips. Every one is listed in README.md with the reason for it. Empty to start with.
//
// A hook's text is pasted into the recompiled function before the instruction at before_vram, with `rdram` and `ctx`
// in scope (ctx->r4..r7 are a0..a3, ctx->r2 is v0, ctx->r29 sp; floats in ctx->f0 ... as .fl / .u32l). Keep the text
// to a call into this file: extern "C" void my_hook(uint8_t* rdram, recomp_context* ctx). The toolkit's
// docs/porting-notes.md has the details (hooks after labels, calling back into game code, extended GBI).
#include "ultramodern/ultra64.h"
#include "ultramodern/ultramodern.hpp"

#include "recomp.h"
#include "librecomp/helpers.hpp"

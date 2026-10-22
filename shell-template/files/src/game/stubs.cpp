// Hand-written replacements for libultra functions that N64Recomp skips (so the game's own copies
// are not recompiled) but N64ModernRuntime does not define. Each one says what the game expects;
// all are listed in README.md. These four were needed by the first game (Aidyn Chronicles); a game that never calls one
// just doesn't use it, and the linker says which others a new game needs ("undefined reference to ..._recomp").
#include "ultramodern/ultra64.h"
#include "ultramodern/ultramodern.hpp"

#include "recomp.h"
#include "librecomp/helpers.hpp"

extern "C" gpr cop0_status_read(recomp_context* ctx);

// __osSiGetAccess / __osSiRelAccess: take and release the SI access semaphore around PIF commands.
// The runtime handles controller I/O itself, so there is nothing to guard.
extern "C" void __osSiGetAccess_recomp(uint8_t* rdram, recomp_context* ctx) {
}

extern "C" void __osSiRelAccess_recomp(uint8_t* rdram, recomp_context* ctx) {
}

// __osSpDeviceBusy: is the RSP (SP) busy? RSP tasks run synchronously inside the runtime, so never.
extern "C" void __osSpDeviceBusy_recomp(uint8_t* rdram, recomp_context* ctx) {
    ctx->r2 = 0;
}

// __osGetSR: reads the CP0 status register. The runtime keeps the emulated value in the context.
extern "C" void __osGetSR_recomp(uint8_t* rdram, recomp_context* ctx) {
    ctx->r2 = cop0_status_read(ctx);
}

// The boot thread (libultra's "main", running bootproc) usually ends by starting the real init thread and then idling
// forever, or returning into a `break` instruction. Where it does the latter, a hook in the game's toml can call this
// instead: the thread sleeps until the program quits, then ends itself the way a destroyed game thread does.
//   [[patches.hook]]
//   func = "recomp_entrypoint"     # N64Recomp's name for the function at the entrypoint
//   before_vram = 0x800004xx       # the `break`
//   text = "extern void shell_park_boot_thread(void); shell_park_boot_thread();"
#include <atomic>
#include <chrono>
#include <thread>

std::atomic_bool shell_quitting{ false };

extern "C" void shell_park_boot_thread(void) {
    while (!shell_quitting.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    throw ultramodern::thread_terminated{};
}

# Porting notes

What the first port on this toolkit (Aidyn Chronicles, released as [Aidyn ReChronicled](https://github.com/spitzdano/AidynReChronicled))
taught, beyond the toolkit's README. Everything here was hit for real.
Addresses and names are Aidyn's examples; the pins are the toolkit's (N64Recomp `ffb39cd`,
N64ModernRuntime `cdf5abb`, RT64 `5473732`).

## Getting the split right

- **Fall-through functions corrupt the stack.** N64Recomp compiles each function on its
  own. If a bogus symbol or a file boundary sits inside a real function, the first half
  "returns" without running the epilogue, so `sp` is wrong when the caller continues.
  The crash appears far from the cause. `tools/find_fallthrough.py` lists every function
  whose last instruction isn't a jump; fix each before chasing anything else.
- **"Failed to find function at 0x..."** means a `jalr` landed on a function nothing calls
  directly (vtables, callback tables), so splat never made it a symbol.
  `tools/find_missing_funcs.py` finds code pointers in data that sit right after a
  `jr $ra`; add them to the symbols.
- **Game functions named like libc** (`strncpy`, `memcpy`, ...): build `RecompiledFuncs`
  with `-fvisibility=hidden` (the shell's CMake does). Exported from the executable,
  they hijack the system libraries' own calls; libdbus crashed inside the game's
  `strncpy`.
- **Renames keep the ROM matching.** Renaming a symbol (e.g. the game's own `osPfs*` so
  N64Recomp recompiles them instead of substituting the runtime's) changes no bytes, so
  `build_elf.sh` still rebuilds the ROM exactly.

## Hooks and replacements

- **`[[patches.hook]]`** pastes C text before the instruction at `before_vram`, with
  `rdram` and `ctx` in scope: `ctx->r4`..`r7` are a0..a3, `r2` is v0, `r29` sp,
  `r16`..`r23` s0..s7; floats are `ctx->f0.fl` / `.u32l` and so on. Keep the text to one call
  into `src/game/patches.cpp`.
- **Hooks are emitted after the label** of their instruction, so a hook on a branch target
  runs on every path into it. A hook can skip code with `goto L_8000CBB8;` (an `L_` label plus
  the address in upper-case hex; it must be a branch target that has a label).
- **A hook on a function's first instruction** sees the arguments. A hook on the
  instruction after a `jal` returns sees the result in `ctx->r2`. Aidyn's
  `MemoryCheck` hook rewrites `osGetMemSize`'s answer that way.
- **`ignored` functions** aren't recompiled. Define them yourself with the same name and
  signature: `extern "C" void Graphics__EndList(uint8_t* rdram, recomp_context* ctx)`.
  The recompiled callers call yours directly.
- **Calling game code from C.** Recompiled functions are plain C functions
  (`extern "C" void Func(uint8_t*, recomp_context*)`). From inside a hook, mid-function,
  every register belongs to someone, so save the whole context:

  ```cpp
  uint32_t call_game(uint8_t* rdram, recomp_context* ctx, void (*fn)(uint8_t*, recomp_context*),
                     uint32_t a0 = 0, uint32_t a1 = 0, uint32_t a2 = 0, uint32_t a3 = 0) {
      recomp_context saved = *ctx;
      ctx->r4 = (int32_t)a0; ctx->r5 = (int32_t)a1; ctx->r6 = (int32_t)a2; ctx->r7 = (int32_t)a3;
      fn(rdram, ctx);
      const uint32_t v0 = (uint32_t)ctx->r2;
      *ctx = saved;
      return v0;
  }
  ```
- **Game memory:** `MEM_W(offset, addr)`, `MEM_H`, `MEM_HU`, `MEM_B` from `recomp.h`,
  with N64 addresses as sign-extended `gpr` values (`(gpr)(int32_t)0x800D8088`).
- **The boot thread.** libultra's boot code may end by returning into a `break`. On
  hardware it never runs again; under the runtime it does. Hook the `break` to call
  `shell_park_boot_thread()` (`src/game/stubs.cpp`).

## More memory

The runtime tells the game it has 8 MB (`osGetMemSize`). The runtime's RDRAM is bigger, so a
game can be told more (Aidyn: 15 MB, used for more map cells loaded at once). Hook where the
game reads the size. Keep anything RT64 reads (display lists, textures, framebuffers)
below 16 MB (`0x81000000`): RT64 masks RDRAM addresses to 24 bits. The port's own data
can go in the space above the game's heap (Aidyn: title images at `0x80F00000`, a cell
table at `0x80F10000`).

## RT64

- **Extended GBI** (`lib/rt64/include/rt64_extended_gbi.h`): write the commands into the
  game's display list from a hook (`MEM_W` the two words of each `GfxCommand`, then move
  the game's list pointer past them). Several things go wrong here:
  - Command sizes differ. `gEXEnable` is 1 command; `gEXSetRectAlign`, `gEXSetScissor` and
    `gEXMatrixGroup` are 2 each. Too small an array silently draws garbage. A stretched
    line was the symptom.
  - Extended GBI is switched off after every frame. Send `gEXEnable` again in each frame
    that uses it.
  - `G_EX_ORIGIN_RIGHT` adds the frame width (320) to x. To pin a rectangle to the right
    edge, keep its 320×240 position and pass `-320 * 4` as the offsets. Texture
    rectangles can't take a negative x.
  - The game's scissor ends at the 4:3 edge. Widen it with
    `gEXSetScissor(G_SC_NON_INTERLACE, G_EX_ORIGIN_LEFT, G_EX_ORIGIN_RIGHT, 0, 0, 0, 240)`.
    Afterwards put back the game's own with a plain `gDPSetScissor` (`0xED`), and reset
    the alignment to `G_EX_ORIGIN_NONE`.
  - For the origins to reach the window's edges, set `hr_option` to
    `HUDRatioMode::Full` in `main.cpp`. The template uses `Original`.
- **Widescreen** (`aspect` in settings) widens the 3D view with no game changes. The 2D
  parts stay 4:3 in the middle. Full-screen 2D menus may look better at 4:3 (Aidyn
  switches the aspect per frame while one is up, with a 10-frame grace period against
  flicker). The game may cull or clip at the old edges: look out for pop-in at the sides.
- **Frame interpolation** (`fps` above the game's rate): RT64 pairs each matrix with last
  frame's by order and interpolates. When pairing goes wrong (stray polygons, smears),
  tag the game's own matrices with `gEXMatrixGroupDecomposed` and an ID that stays the
  same across frames (Aidyn: scene pointer × golden ratio ^ node). Use
  `G_EX_ORDER_LINEAR`, and set the default group back afterwards. Animations that loop
  or snap can stutter more visibly at high rates; Aidyn's walk cycle stopped for 3 ticks
  every stride.
- **Supersampling** = `resolutionMultiplier` and `downsampleMultiplier` both multiplied
  by the factor. It smooths edges MSAA can't, such as texture-alpha cut-outs (hair,
  leaves).
- **Texture packs** match textures by RT64's TMEM hash (`TMEMHasher`, version 5). The hash
  covers what was loaded into TMEM, row by row with the padding left out, not the source
  image. To name replacements for images the game hasn't drawn yet, rebuild TMEM the way
  RT64's `loadToTMEMCommon` does:
  - LoadTile from column 0;
  - odd rows' 32-bit words swapped (XOR 4);
  - RGBA32 split into red-green in the low half and blue-alpha in the high half;
  - a CI palette's entries ×4 at `0x800`.

  Then hash it with `shell-template/optional/tmemhash`. `RECOMP_DUMP_TEXTURES=<dir>` dumps
  what the game really loads, to check against.
- **Big images drawn in strips** hash per strip, and the strips move with the draw
  position, so one image can have hundreds of hashes. Aidyn widens every such draw to
  full-width strips on a fixed grid and clips the rectangles back, so each image has
  one fixed set of strips to replace.
- **Framebuffer ranges skip texture replacement.** RT64 tracks the RDRAM ranges the RDP
  rendered into. A texture later read from such a range goes through the framebuffer
  path and is never replaced. When a replaced image sometimes shows its original, check
  this first: Aidyn logged RT64's framebuffer ranges against the image's address for that
  (`AIDYN_PAGE_LOG`). There the cause turned out to be something else: the page's reveal
  clip stopped early.
- **`detectDataPath = false`**, or RT64 makes an empty `~/.config/.rt64`.

## Audio and input

- **Audio buffer maths underflows.** Games size the next audio buffer as roughly "one VI of
  samples minus what is still queued", in unsigned arithmetic. If the host device starts
  late and the queue grows past a VI, that wraps and the game crashes ("Audio list
  overrun!"). The shell reports at most one VI queued and drops audio past 100 ms.
- **Unknown RSP tasks abort** with the task's details (`main.cpp`). A second microcode
  (JPEG, video, another audio ucode) needs its own RSPRecomp toml in `RSP_CONFIGS`.
- **The Controller Pak** isn't in the runtime: see `shell-template/README.md`
  (`optional/pak`). Its `.mpk` is the raw image emulators use.

## Testing without a person

- **`RECOMP_PAD_FILE=<file>`**: the shell reads `<hex buttons> <x> <y>` from the file on
  every poll. A script writes button presses into it with sleeps between them. That
  replays a route to any screen (Aidyn: `tools/dev/pad.sh`, `loadgame.sh`). Screenshots
  on Hyprland: `grim -g "<x>,<y> <w>x<h>"` of the window.
- **`RECOMP_SETTINGS_DIR`** runs with a test `settings.json` without touching the player's.
- **`RECOMP_FPS=1`** prints the game's frame rate, the shown rate (interpolated) and the
  largest display list. Compare that with the game's own buffer size before adding
  commands to it.
- **`trace_mode = true`** in the toml prints every function call (slow, but it finds the
  last function before a crash).
- **Process names are cut to 15 characters**, so `pgrep -x AidynReChronicled` never
  matches. Use `pgrep -f build/cmake/<exe>`. A wait loop such as
  `until ! pgrep -f <pattern>` matches its own command line and never ends: wait on a
  PID instead.

## Wayland

An SDL window only gets its display, and so a Vulkan surface, once the compositor has
configured it. RT64 is created right after the window, so the shell pumps events until
`SDL_GetWindowDisplayIndex` answers (at most 3 s).

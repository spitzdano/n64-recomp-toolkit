# shell-template

The runtime shell every project starts from: the native program around the recompiled code.
It comes from the first game ported on this toolkit's pins (Aidyn Chronicles, now
[Aidyn ReChronicled](https://github.com/spitzdano/AidynReChronicled)), with the game-specific parts taken out
and the names turned into `__PLACEHOLDERS__`. `new-game.sh` copies `files/` into every new
project, filled in from the ROM header, next to `template/`.

## files/ (copied into every project)

| File | Does |
|---|---|
| `CMakeLists.txt` | RT64 and N64ModernRuntime as subprojects, `RecompiledFuncs/` as a static library with hidden visibility (game functions named like libc ones must not leak out), the executable `__EXE__` |
| `src/main/main.cpp` | SDL window (waits for Wayland to configure it), `--rom` (checked by XXH3, stored by librecomp), RSP task dispatch (audio → recompiled `aspMain`, anything else aborts with the task's details), graphics config from settings, F11/Alt+Enter fullscreen, Shift+Esc quit |
| `src/main/rt64_context.*` | RT64 glue (from RecompFrontend): resolution and supersampling, aspect, MSAA capped to the GPU, texture packs, `RECOMP_FPS`, `RECOMP_DUMP_TEXTURES` |
| `src/main/settings.*` | `settings.json` in the data folder, written with defaults on first run; bad values stop the program with the reason |
| `src/main/input.*` | First SDL game controller plus keyboard, on port 1; right stick → C buttons; `RECOMP_PAD_FILE` for scripted tests |
| `src/main/audio.*` | SDL audio from Zelda64Recomp; reports at most one VI of queued samples (games underflow their buffer maths otherwise) |
| `src/main/register_overlays.cpp` | Registers N64Recomp's section table |
| `src/game/stubs.cpp` | libultra functions N64Recomp skips but the runtime doesn't define (`__osSiGetAccess`, `__osSiRelAccess`, `__osSpDeviceBusy`, `__osGetSR`), and `shell_park_boot_thread` for a boot thread that returns into `break` |
| `src/game/patches.cpp` | Empty: where the game's hooks go |
| `tools/build_game.sh` | Configures (clang, Ninja, Release) and builds `build/cmake/__EXE__` |

Placeholders `new-game.sh` fills in, besides the ones `template/` uses:

| Placeholder | From | Aidyn's would be |
|---|---|---|
| `__EXE__` | the project name in CamelCase + `Recomp` (executable, CMake project, data folder) | `AidynRecomp` |
| `__TITLE__` | the header name in words (window title, messages) | `Aidyn Chronicles` |
| `__GAME_ID__` | `<name>.n64.<region>.1.<version>` | `aidyn.n64.us.1.0` |
| `__ROM_XXH3__` | `xxhsum -H3 baserom.z64` (what librecomp checks a ROM by) | `0x79127D0E9CAF38BC` |
| `__HEADER_NAME_C__` | header bytes 0x20–0x33 as a C string (librecomp's "right game, wrong version" check) | `AIDYN_CHRONICLES` |

Settings (`~/.local/share/__EXE__/settings.json`), defaults chosen for a game nobody has
looked at yet: `render_height` 1080, `aspect` `"4:3"` (or `"16:9"`, `"21:9"`, any W:H,
`"window"`), `msaa` 4, `supersampling` 1, `fps` `"original"` (or `"display"`, or a number:
RT64 interpolates), `fullscreen` false, `texture_packs` [].

## optional/ (not copied; add by hand when a game needs it)

**`pak/pak.cpp`: Controller Pak.** A 32 KiB pack in port 1 as one `.mpk` file (the raw image
emulators use), flushed on every write. Only the raw block access is replaced
(`__osContRamRead/Write`, `osPfsIsPlug`, `__osPfsGetStatus`, `osPfsChecker`); the game's own
libultra file system runs on top. To use it:

1. Copy it to `src/game/pak.cpp` and add it to `add_executable` in `CMakeLists.txt`.
2. Rename the game's own `osPfs*` / `__osPfs*` / `__osCheckId`-family functions in the
   symbols (e.g. `osPfsInitPak` → `game_osPfsInitPak`) so N64Recomp recompiles them
   instead of substituting the runtime's "no pak" versions. Aidyn's list:
   `osPfsInitPak osPfsFreeBlocks osPfsAllocateFile osPfsDeleteFile osPfsFileState
   osPfsReadWriteFile osPfsRepairId osPfsFindFile __osCheckId __osCheckPackId __osGetId
   __osPfsCheckRamArea __osPfsRWInode __osPfsSelectBank __osRepairPackId`. The ROM still
   rebuilds byte for byte (names only).
3. In `main()`, before `recomp::start`: `shell_pak_set_path(data_folder() / "<name>.mpk");`
   (declare `void shell_pak_set_path(const std::filesystem::path&);`).

**`tmemhash/tmemhash.cpp`: RT64's texture hash** for textures the game hasn't drawn yet, so a
texture-pack builder can name replacements straight from the ROM (Aidyn's `tools/hdui` does).
Reads one texture per line on stdin (`<4096-byte TMEM file> fmt siz line tmem palette width
height tlut`), prints one hash per line. Build it next to the game:

```cmake
add_executable(tmemhash tools/tmemhash.cpp lib/rt64/src/common/rt64_load_types.cpp)
target_include_directories(tmemhash PRIVATE ${CMAKE_SOURCE_DIR}/lib/rt64/src ${CMAKE_SOURCE_DIR}/lib/rt64/src/contrib)
```

## Left out on purpose

Everything Aidyn-only stayed in Aidyn's repo: two ROM versions with a title-screen switch,
4:3 menus inside a widescreen game, the right-stick camera, draw distance, HUD placement,
title branding, the framebuffer page log. `docs/porting-notes.md` explains the techniques
behind them.

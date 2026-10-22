// __TITLE__ (__INTERNAL_NAME__, __GAMECODE__ v__VERSION__, recompiled): runtime shell.
//
// From the n64-recomp-toolkit's shell-template (first used for Aidyn Chronicles), modelled on Zelda64Recomp's main.cpp
// and stripped to what the runtime needs to boot a game: an SDL window for RT64, SDL audio, SDL input, and the
// recompiled audio microcode. No launcher UI, no mods. The player's own ROM is given with --rom (or remembered from
// the last run, since librecomp stores a copy of a validated ROM in the data folder).
#include "settings.h"
#include <atomic>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>

#include "ultramodern/ultra64.h"
#include "ultramodern/ultramodern.hpp"
#include "ultramodern/config.hpp"
#include "librecomp/game.hpp"
#include "librecomp/rsp.hpp"

#define SDL_MAIN_HANDLED
#include "SDL2/SDL.h"

#include "rt64_context.h"
#include "input.h"
#include "audio.h"

extern RspUcodeFunc aspMain;
extern "C" void recomp_entrypoint(uint8_t* rdram, recomp_context* ctx);
gpr get_entrypoint_address();
void shell_register_overlays();

extern std::atomic_bool shell_quitting; // src/game/stubs.cpp

static SDL_Window* window = nullptr;

static void quit() {
    shell_quitting.store(true);
    ultramodern::quit();
}

[[noreturn]] static void fatal(const char* fmt, const char* arg = "") {
    fprintf(stderr, fmt, arg);
    fputc('\n', stderr);
    std::fflush(stderr);
    std::exit(EXIT_FAILURE);
}

static void message_box(const char* msg) {
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "__TITLE__", msg, window);
}

static ultramodern::gfx_callbacks_t::gfx_data_t create_gfx() {
    SDL_SetHint(SDL_HINT_GAMECONTROLLER_USE_BUTTON_LABELS, "0");
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER | SDL_INIT_AUDIO) != 0) {
        fatal("Failed to initialize SDL2: %s", SDL_GetError());
    }
    fprintf(stdout, "SDL video driver: %s\n", SDL_GetCurrentVideoDriver());
    return {};
}

static ultramodern::renderer::WindowHandle create_window(ultramodern::gfx_callbacks_t::gfx_data_t) {
    window = SDL_CreateWindow("__TITLE__", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                              1280, 960, SDL_WINDOW_RESIZABLE | SDL_WINDOW_VULKAN);
    if (window == nullptr) {
        fatal("Failed to create window: %s", SDL_GetError());
    }
    // On Wayland a window only learns its display (and can only get a Vulkan surface) once the
    // compositor has configured it, which needs the event loop to run. RT64 is created right after this
    // returns, so wait here until the window is ready (a few frames at most).
    SDL_ShowWindow(window);
    for (int i = 0; i < 300 && SDL_GetWindowDisplayIndex(window) < 0; i++) {
        SDL_PumpEvents();
        SDL_Delay(10);
    }
    if (SDL_GetWindowDisplayIndex(window) < 0) {
        fprintf(stderr, "Warning: the window still has no display after 3 s (%s); continuing\n", SDL_GetError());
    }
    return ultramodern::renderer::WindowHandle{ window };
}

static void update_gfx(void*) {
    SDL_Event event;
    while (SDL_PollEvent(&event)) {
        switch (event.type) {
        case SDL_QUIT:
            quit();
            return;
        case SDL_KEYDOWN:
            if (event.key.keysym.scancode == SDL_SCANCODE_F11 || (event.key.keysym.scancode == SDL_SCANCODE_RETURN && (event.key.keysym.mod & KMOD_ALT))) {
                bool fullscreen = (SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN_DESKTOP) != 0;
                SDL_SetWindowFullscreen(window, fullscreen ? 0 : SDL_WINDOW_FULLSCREEN_DESKTOP);
            }
            else if (event.key.keysym.scancode == SDL_SCANCODE_ESCAPE && (event.key.keysym.mod & KMOD_SHIFT)) {
                quit();
                return;
            }
            break;
        default:
            break;
        }
        shell::input::handle_event(event);
    }
}

// Audio tasks run the recompiled aspMain (rsp/aspMain.cpp, from aspMain.__REGION__.toml). Anything else is a bug in the
// port: graphics tasks go to RT64 (never here), and no other microcode is known yet. Fail visibly, with the task's
// details, so a new microcode (a second audio ucode, a JPEG or video decoder) shows up at once.
static RspUcodeFunc* get_rsp_microcode(const OSTask* task) {
    if (task->t.type == M_AUDTASK) {
        return aspMain;
    }
    fprintf(stderr, "Unknown RSP task type %" PRIu32 ": ucode 0x%08" PRIX32 ", ucode_data 0x%08" PRIX32 ", data_ptr 0x%08" PRIX32 "\n",
            task->t.type, task->t.ucode, task->t.ucode_data, task->t.data_ptr);
    std::abort();
}

// What is plugged into each port. RumblePak makes the runtime answer the game's rumble probe. The runtime has no
// Controller Pak: a game that saves to one needs optional/pak from the toolkit's shell-template.
static ultramodern::input::connected_device_info_t get_connected_device_info(int controller_num) {
    if (controller_num == 0) {
        return { ultramodern::input::Device::Controller, ultramodern::input::Pak::RumblePak };
    }
    return { ultramodern::input::Device::None, ultramodern::input::Pak::None };
}

// Saves, settings.json, the stored ROM and texture packs: $XDG_DATA_HOME/__EXE__ (~/.local/share/__EXE__).
static std::filesystem::path data_folder() {
    const char* xdg = std::getenv("XDG_DATA_HOME");
    std::filesystem::path base = (xdg != nullptr && *xdg != '\0') ? std::filesystem::path(xdg) : std::filesystem::path(std::getenv("HOME") ? std::getenv("HOME") : ".") / ".local" / "share";
    return base / "__EXE__";
}

static const char8_t game_id[] = u8"__GAME_ID__";

int main(int argc, char** argv) {
    std::filesystem::path rom_path;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--rom") == 0 && i + 1 < argc) {
            rom_path = argv[++i];
        }
        else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("usage: %s [--rom <ROM>]\n"
                   "  --rom       your __TITLE__ ROM (__GAMECODE__ v__VERSION__): checked and remembered after the first run\n"
                   "  F11 or Alt+Enter: fullscreen   Shift+Esc: quit\n", argv[0]);
            return 0;
        }
        else {
            fprintf(stderr, "Unknown argument: %s (try --help)\n", argv[i]);
            return 2;
        }
    }

    std::filesystem::create_directories(data_folder());
    recomp::register_config_path(data_folder());
    // settings.json: RECOMP_SETTINGS_DIR points at another folder (tests).
    const char* settings_dir = std::getenv("RECOMP_SETTINGS_DIR");
    shell::settings::load(settings_dir != nullptr && *settings_dir != '\0' ? std::filesystem::path(settings_dir) : data_folder());

    recomp::GameEntry entry{
        .rom_hash = __ROM_XXH3__ULL, // XXH3-64 of the big-endian ROM (SHA-1 __ROM_SHA1__)
        .internal_name = "__HEADER_NAME_C__",
        .display_name = "__TITLE__",
        .game_id = game_id,
        .mod_game_id = "__GAME__",
        .save_type = recomp::SaveType::None, // set to the game's save chip (Eep4k, Eep16k, Sram, Flashram) if it has one
        .is_enabled = true,
        .has_compressed_code = false,
        .entrypoint_address = get_entrypoint_address(),
        .entrypoint = recomp_entrypoint,
    };
    recomp::register_game(entry);
    shell_register_overlays();

    if (!rom_path.empty()) {
        switch (recomp::select_rom(rom_path, game_id)) {
        case recomp::RomValidationError::Good:
            printf("Stored the ROM.\n");
            fflush(stdout);
            break;
        case recomp::RomValidationError::FailedToOpen:
            fatal("Could not open ROM: %s", rom_path.c_str());
        case recomp::RomValidationError::NotARom:
            fatal("Not an N64 ROM: %s", rom_path.c_str());
        case recomp::RomValidationError::IncorrectVersion:
            fatal("This is __TITLE__, but not the __GAMECODE__ v__VERSION__ dump this port was made from: %s", rom_path.c_str());
        default:
            fatal("This is not __TITLE__ (__GAMECODE__ v__VERSION__): %s", rom_path.c_str());
        }
    }
    recomp::check_all_stored_roms();
    if (!recomp::is_rom_valid(game_id)) {
        fatal("No ROM yet. Run once with --rom <path to your __TITLE__ ROM>.");
    }

    shell::audio::init(48000);

    const shell::settings::Graphics& player = shell::settings::graphics();
    ultramodern::renderer::GraphicsConfig graphics{};
    graphics.developer_mode = false;
    graphics.res_option = ultramodern::renderer::Resolution::Auto;
    graphics.wm_option = player.fullscreen ? ultramodern::renderer::WindowMode::Fullscreen : ultramodern::renderer::WindowMode::Windowed;
    // Original: extended-GBI origins (G_EX_ORIGIN_LEFT/RIGHT) stay inside the 4:3 area. Full lets them reach the window's
    // edges, for a game patched to put its HUD there.
    graphics.hr_option = ultramodern::renderer::HUDRatioMode::Original;
    graphics.api_option = ultramodern::renderer::GraphicsApi::Auto;
    graphics.ar_option = ultramodern::renderer::AspectRatio::Original;
    switch (player.msaa) {
        case 2: graphics.msaa_option = ultramodern::renderer::Antialiasing::MSAA2X; break;
        case 4: graphics.msaa_option = ultramodern::renderer::Antialiasing::MSAA4X; break;
        case 8: graphics.msaa_option = ultramodern::renderer::Antialiasing::MSAA8X; break;
        default: graphics.msaa_option = ultramodern::renderer::Antialiasing::None; break;
    }
    // Above the game's own rate RT64 draws in-between frames, pairing each matrix with the one from the last frame and
    // interpolating them. That needs no game changes to start with; objects that jump or smear need matrix-group tags
    // (see the toolkit's docs/porting-notes.md).
    switch (player.fps) {
        case shell::settings::Fps::Original:
            graphics.rr_option = ultramodern::renderer::RefreshRate::Original;
            graphics.rr_manual_value = 60;
            break;
        case shell::settings::Fps::Display:
            graphics.rr_option = ultramodern::renderer::RefreshRate::Display;
            graphics.rr_manual_value = 60;
            break;
        case shell::settings::Fps::Limit:
            graphics.rr_option = ultramodern::renderer::RefreshRate::Manual;
            graphics.rr_manual_value = player.fps_limit;
            break;
    }
    graphics.hpfb_option = ultramodern::renderer::HighPrecisionFramebuffer::Auto;
    graphics.ds_option = 1;
    ultramodern::renderer::set_graphics_config(graphics);

    recomp::Configuration cfg;
    cfg.project_version = recomp::Version(0, 1, 0, "-dev");
    cfg.window_handle = {}; // not default-initialised by Configuration: garbage here is used as the window
    cfg.rsp_callbacks = { .get_rsp_microcode = get_rsp_microcode };
    cfg.renderer_callbacks = { .create_render_context = shell::create_render_context };
    cfg.audio_callbacks = { .queue_samples = shell::audio::queue_samples, .get_frames_remaining = shell::audio::get_frames_remaining, .set_frequency = shell::audio::set_frequency };
    cfg.input_callbacks = { .poll_input = shell::input::poll, .get_input = shell::input::get, .set_rumble = shell::input::set_rumble, .get_connected_device_info = get_connected_device_info };
    cfg.gfx_callbacks = { .create_gfx = create_gfx, .create_window = create_window, .update_gfx = update_gfx };
    cfg.events_callbacks = { .vi_callback = nullptr, .gfx_init_callback = nullptr };
    cfg.error_handling_callbacks = { .message_box = message_box };
    cfg.threads_callbacks = { .get_game_thread_name = nullptr };
    cfg.message_queue_control.requeue_pi = true;
    cfg.message_queue_control.requeue_ai = true;
    cfg.message_queue_control.requeue_sp = true;
    cfg.message_queue_control.requeue_dp = true;
    cfg.message_queue_control.requeue_timer = true;

    // Start the game right away; the runtime loads the stored ROM when its game thread sees this.
    recomp::start_game(game_id, "");
    recomp::start(cfg);
    return EXIT_SUCCESS;
}

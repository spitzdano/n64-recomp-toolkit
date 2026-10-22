// Minimal input: the first SDL game controller, with the keyboard as a fallback so the game can
// be tested without a pad. Everything feeds N64 port 1. A starting point: map the buttons the way this game wants.
//
// Pad:       A/B -> A/B   right stick -> C buttons   LT -> Z   LB/RB -> L/R   RT -> R
//            left stick, D-pad and Start as expected; X and Y unused
// Keyboard:  arrows = stick, Z = A, X = B, C = Z, Enter = Start
//            IJKL = C buttons, Q = L, E = R, keypad 8456 = D-pad
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <mutex>

#include "SDL2/SDL.h"

#include "input.h"

namespace {
    enum N64Button : uint16_t {
        A = 0x8000, B = 0x4000, Z = 0x2000, START = 0x1000,
        DU = 0x0800, DD = 0x0400, DL = 0x0200, DR = 0x0100,
        L = 0x0020, R = 0x0010,
        CU = 0x0008, CD = 0x0004, CL = 0x0002, CR = 0x0001,
    };

    SDL_GameController* pad = nullptr;
    std::mutex pad_mutex;
    constexpr float stick_deadzone = 0.15f;

    constexpr float c_threshold = 0.5f; // how far the right stick goes before it presses a C button

    bool scanned = false;

    void open_first_pad() {
        if (pad != nullptr) {
            return;
        }
        for (int i = 0; i < SDL_NumJoysticks(); i++) {
            if (SDL_IsGameController(i)) {
                pad = SDL_GameControllerOpen(i);
                if (pad != nullptr) {
                    fprintf(stdout, "Controller: %s\n", SDL_GameControllerName(pad));
                    return;
                }
            }
        }
    }

    float axis(SDL_GameControllerAxis a) {
        float v = SDL_GameControllerGetAxis(pad, a) / 32767.0f;
        return std::clamp(v, -1.0f, 1.0f);
    }

    float apply_deadzone(float v) {
        float mag = std::fabs(v);
        if (mag < stick_deadzone) {
            return 0.0f;
        }
        return std::copysign((mag - stick_deadzone) / (1.0f - stick_deadzone), v);
    }
}

void shell::input::handle_event(const SDL_Event& event) {
    std::lock_guard lock{ pad_mutex };
    switch (event.type) {
    case SDL_CONTROLLERDEVICEADDED:
        open_first_pad();
        break;
    case SDL_CONTROLLERDEVICEREMOVED:
        if (pad != nullptr && event.cdevice.which == SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(pad))) {
            SDL_GameControllerClose(pad);
            pad = nullptr;
            open_first_pad();
        }
        break;
    default:
        break;
    }
}

void shell::input::poll() {
    // Pads are opened from SDL's device-added events (and once at startup); scanning SDL's device list on every
    // controller poll from the game's input thread was needless, and raced SDL's own thread.
    std::lock_guard lock{ pad_mutex };
    if (!scanned) {
        scanned = true;
        open_first_pad();
    }
}

bool shell::input::get(int controller_num, uint16_t* buttons, float* x, float* y) {
    if (controller_num != 0) {
        return false;
    }

    uint16_t b = 0;
    float sx = 0.0f, sy = 0.0f;

    {
        std::lock_guard lock{ pad_mutex };
        if (pad != nullptr) {
            auto down = [&](SDL_GameControllerButton btn) { return SDL_GameControllerGetButton(pad, btn) != 0; };
            if (down(SDL_CONTROLLER_BUTTON_A)) b |= A;
            if (down(SDL_CONTROLLER_BUTTON_B)) b |= B;
            if (down(SDL_CONTROLLER_BUTTON_START)) b |= START;
            if (down(SDL_CONTROLLER_BUTTON_DPAD_UP)) b |= DU;
            if (down(SDL_CONTROLLER_BUTTON_DPAD_DOWN)) b |= DD;
            if (down(SDL_CONTROLLER_BUTTON_DPAD_LEFT)) b |= DL;
            if (down(SDL_CONTROLLER_BUTTON_DPAD_RIGHT)) b |= DR;
            if (down(SDL_CONTROLLER_BUTTON_LEFTSHOULDER)) b |= L;
            if (down(SDL_CONTROLLER_BUTTON_RIGHTSHOULDER)) b |= R;
            if (axis(SDL_CONTROLLER_AXIS_TRIGGERLEFT) > 0.3f) b |= Z;
            if (axis(SDL_CONTROLLER_AXIS_TRIGGERRIGHT) > 0.3f) b |= R;
            const float cx = axis(SDL_CONTROLLER_AXIS_RIGHTX), cy = axis(SDL_CONTROLLER_AXIS_RIGHTY);
            if (cx < -c_threshold) b |= CL;
            if (cx > c_threshold) b |= CR;
            if (cy < -c_threshold) b |= CU;
            if (cy > c_threshold) b |= CD;
            sx = apply_deadzone(axis(SDL_CONTROLLER_AXIS_LEFTX));
            sy = -apply_deadzone(axis(SDL_CONTROLLER_AXIS_LEFTY));
        }
    }

    const Uint8* keys = SDL_GetKeyboardState(nullptr);
    if (keys[SDL_SCANCODE_Z]) b |= A;
    if (keys[SDL_SCANCODE_X]) b |= B;
    if (keys[SDL_SCANCODE_C]) b |= Z;
    if (keys[SDL_SCANCODE_RETURN]) b |= START;
    if (keys[SDL_SCANCODE_Q]) b |= L;
    if (keys[SDL_SCANCODE_E]) b |= R;
    if (keys[SDL_SCANCODE_I]) b |= CU;
    if (keys[SDL_SCANCODE_K]) b |= CD;
    if (keys[SDL_SCANCODE_J]) b |= CL;
    if (keys[SDL_SCANCODE_L]) b |= CR;
    if (keys[SDL_SCANCODE_KP_8]) b |= DU;
    if (keys[SDL_SCANCODE_KP_5]) b |= DD;
    if (keys[SDL_SCANCODE_KP_4]) b |= DL;
    if (keys[SDL_SCANCODE_KP_6]) b |= DR;
    if (keys[SDL_SCANCODE_RIGHT]) sx = 1.0f;
    if (keys[SDL_SCANCODE_LEFT]) sx = -1.0f;
    if (keys[SDL_SCANCODE_UP]) sy = 1.0f;
    if (keys[SDL_SCANCODE_DOWN]) sy = -1.0f;

    // Test aid for automated play-testing: RECOMP_PAD_FILE names a text file holding "<hex buttons> <x> <y>" (N64 button
    // bits as above, the stick -1..1). Read on every poll and ORed in; absent or unreadable means nothing.
    static const char* pad_file = std::getenv("RECOMP_PAD_FILE");
    if (pad_file != nullptr) {
        std::ifstream f{ pad_file };
        unsigned fb = 0;
        float fx = 0.0f, fy = 0.0f;
        if (f >> std::hex >> fb >> std::dec >> fx >> fy) {
            b |= static_cast<uint16_t>(fb);
            if (fx != 0.0f || fy != 0.0f) {
                sx = fx;
                sy = fy;
            }
        }
    }

    *buttons = b;
    *x = sx;
    *y = sy;
    return true;
}

void shell::input::set_rumble(int controller_num, bool rumble) {
    std::lock_guard lock{ pad_mutex };
    if (controller_num == 0 && pad != nullptr) {
        SDL_GameControllerRumble(pad, rumble ? 0xFFFF : 0, rumble ? 0xFFFF : 0, rumble ? 0xFFFFFFFF : 0);
    }
}

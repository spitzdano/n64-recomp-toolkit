#pragma once
#include <cstdint>

union SDL_Event;

namespace shell::input {
    void handle_event(const SDL_Event& event);
    void poll();
    bool get(int controller_num, uint16_t* buttons, float* x, float* y);
    void set_rumble(int controller_num, bool rumble);
}

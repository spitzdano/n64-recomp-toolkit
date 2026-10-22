// Player settings, read from settings.json in the data folder (written with defaults on first run).
#pragma once

#include <filesystem>
#include <string>
#include <vector>

namespace shell::settings {
    enum class Aspect {
        Original,   // "4:3": black bars at the sides
        Ratio,      // "W:H" wider than 4:3 ("16:9", "21:9", ...): RT64 widens the 3D view; 2D stays 4:3 in the middle
        Window,     // "window": as wide as the window
    };

    enum class Fps {
        Original,   // "original": the game's own rate, nothing interpolated
        Display,    // "display": as fast as the display refreshes (RT64 interpolates in-between frames)
        Limit,      // a number: up to that many frames a second (interpolated)
    };

    struct Graphics {
        int render_height = 1080;    // internal resolution in lines (240 = N64); 0 = largest integer scale that fits the window
        Aspect aspect = Aspect::Original;
        std::string aspect_text = "4:3"; // as written in settings.json
        double aspect_ratio = 4.0 / 3.0; // width / height, for Aspect::Ratio
        int msaa = 4;                // 0, 2, 4 or 8 (capped to what the GPU supports)
        int supersampling = 1;       // 1 (off), 2, 3 or 4: render that many times render_height and scale down (smoother edges)
        Fps fps = Fps::Original;
        int fps_limit = 60;          // for Fps::Limit
        bool fullscreen = false;
        std::vector<std::string> texture_packs; // RT64 packs in <data>/texture-packs (folders or .rtz), later ones win
    };

    // Loads (or creates) <folder>/settings.json. A file that can't be parsed stops the program with the reason,
    // rather than silently using defaults.
    void load(const std::filesystem::path& folder);
    const std::filesystem::path& folder();
    const Graphics& graphics();
}

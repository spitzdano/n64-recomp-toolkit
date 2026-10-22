#include "settings.h"

#include <cstdio>
#include <cstdlib>
#include <fstream>

#include "json/json.hpp"

namespace {
    shell::settings::Graphics g_graphics;
    std::filesystem::path g_folder;

    [[noreturn]] void bad(const std::filesystem::path& path, const std::string& why) {
        fprintf(stderr, "%s: %s\n", path.c_str(), why.c_str());
        std::exit(EXIT_FAILURE);
    }

    // "W:H" -> W / H, or 0 when it isn't two positive numbers.
    double parse_ratio(const std::string& text) {
        const size_t colon = text.find(':');
        if (colon == std::string::npos) {
            return 0.0;
        }
        try {
            size_t used_w = 0, used_h = 0;
            const double w = std::stod(text.substr(0, colon), &used_w);
            const double h = std::stod(text.substr(colon + 1), &used_h);
            if (used_w != colon || used_h != text.size() - colon - 1 || !(w > 0.0) || !(h > 0.0)) {
                return 0.0;
            }
            return w / h;
        }
        catch (const std::exception&) {
            return 0.0;
        }
    }
}

void shell::settings::load(const std::filesystem::path& folder) {
    g_folder = folder;
    const std::filesystem::path path = folder / "settings.json";
    std::error_code ec;
    if (!std::filesystem::exists(path, ec)) {
        nlohmann::ordered_json j;
        j["graphics"]["render_height"] = g_graphics.render_height;
        j["graphics"]["aspect"] = g_graphics.aspect_text;
        j["graphics"]["msaa"] = g_graphics.msaa;
        j["graphics"]["supersampling"] = g_graphics.supersampling;
        j["graphics"]["fps"] = "original";
        j["graphics"]["fullscreen"] = g_graphics.fullscreen;
        j["graphics"]["texture_packs"] = g_graphics.texture_packs;
        std::ofstream out(path);
        out << j.dump(4) << "\n";
        if (!out) {
            bad(path, "cannot write the default settings");
        }
        return;
    }

    nlohmann::json j;
    try {
        std::ifstream in(path);
        j = nlohmann::json::parse(in);
        const auto& gfx = j.value("graphics", nlohmann::json::object());
        g_graphics.render_height = gfx.value("render_height", g_graphics.render_height);
        g_graphics.msaa = gfx.value("msaa", g_graphics.msaa);
        g_graphics.supersampling = gfx.value("supersampling", g_graphics.supersampling);
        g_graphics.fullscreen = gfx.value("fullscreen", g_graphics.fullscreen);
        g_graphics.texture_packs = gfx.value("texture_packs", g_graphics.texture_packs);

        // "fps": "original", "display" or a number of frames a second.
        const nlohmann::json fps = gfx.value("fps", nlohmann::json("original"));
        if (fps.is_number_integer()) {
            g_graphics.fps = Fps::Limit;
            g_graphics.fps_limit = fps.get<int>();
            if (g_graphics.fps_limit < 30 || g_graphics.fps_limit > 1000) {
                bad(path, "graphics.fps must be \"original\", \"display\" or 30..1000");
            }
        }
        else if (fps == "original") {
            g_graphics.fps = Fps::Original;
        }
        else if (fps == "display") {
            g_graphics.fps = Fps::Display;
        }
        else {
            bad(path, "graphics.fps must be \"original\", \"display\" or 30..1000, not " + fps.dump());
        }

        const std::string aspect = gfx.value("aspect", g_graphics.aspect_text);
        g_graphics.aspect_text = aspect;
        if (aspect == "4:3") {
            g_graphics.aspect = Aspect::Original;
        }
        else if (aspect == "window") {
            g_graphics.aspect = Aspect::Window;
        }
        else {
            const double ratio = parse_ratio(aspect);
            if (ratio < 4.0 / 3.0 || ratio > 4.0) {
                bad(path, "graphics.aspect must be \"4:3\", \"window\" or a width:height from 4:3 to 4:1 (\"16:9\", "
                          "\"21:9\", \"43:18\"...), not \"" + aspect + "\"");
            }
            g_graphics.aspect = Aspect::Ratio;
            g_graphics.aspect_ratio = ratio;
        }
    }
    catch (const nlohmann::json::exception& e) {
        bad(path, e.what());
    }
    if (g_graphics.render_height != 0 && (g_graphics.render_height < 240 || g_graphics.render_height > 4320)) {
        bad(path, "graphics.render_height must be 0 (fit the window) or 240..4320");
    }
    if (g_graphics.msaa != 0 && g_graphics.msaa != 2 && g_graphics.msaa != 4 && g_graphics.msaa != 8) {
        bad(path, "graphics.msaa must be 0, 2, 4 or 8");
    }
    if (g_graphics.supersampling < 1 || g_graphics.supersampling > 4) {
        bad(path, "graphics.supersampling must be 1 (off), 2, 3 or 4");
    }
}

const std::filesystem::path& shell::settings::folder() {
    return g_folder;
}

const shell::settings::Graphics& shell::settings::graphics() {
    return g_graphics;
}

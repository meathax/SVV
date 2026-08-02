#define SDL_MAIN_HANDLED
#include <SDL.h>
#include <SDL_syswm.h>
#include <svdpi.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>
#include <thread>

namespace {
constexpr int kMaxWidth = 352;
constexpr int kMaxHeight = 240;
constexpr int kMaxPixels = kMaxWidth * kMaxHeight;

SDL_Window* g_window = nullptr;
SDL_Renderer* g_renderer = nullptr;
SDL_Texture* g_texture = nullptr;
SDL_GameController* g_controller = nullptr;
SDL_AudioDeviceID g_audio_device = 0;
SDL_AudioStream* g_audio_stream = nullptr;
int g_audio_output_rate = 48000;
int g_audio_source_rate = 0;
Uint32 g_audio_prime_bytes = 0;
Uint32 g_audio_max_queue_bytes = 0;
Uint32 g_audio_queue_highwater = 0;
bool g_audio_started = false;
uint64_t g_audio_source_samples = 0;
uint64_t g_audio_nonzero_samples = 0;
uint64_t g_audio_queued_frames = 0;
uint64_t g_audio_dropped_frames = 0;
uint64_t g_audio_underflows = 0;
uint64_t g_audio_queue_resets = 0;
uint64_t g_audio_stream_reconfigs = 0;
uint64_t g_audio_errors = 0;
std::array<uint32_t, kMaxPixels> g_pixels{};
std::array<uint32_t, kMaxPixels> g_previous{};
int g_width = 336;
int g_height = 240;
uint16_t g_p1 = 0;
uint16_t g_system = 0;
bool g_quit = false;
bool g_have_frame = false;
uint32_t g_previous_checksum = 0;
uint64_t g_checksum_changes = 0;
std::chrono::steady_clock::time_point g_last_capture{};
bool g_have_capture = false;
long long g_pending_frame = -1;
std::filesystem::path g_lockstep_dir;
std::filesystem::path g_input_journal_dir;
bool g_lockstep_initialized = false;
bool g_lockstep_ready = false;
bool g_lockstep_trace_stopped = false;
int g_lockstep_trace_start_frame = 0;
std::string g_lockstep_trace_buffer;
std::atomic<bool> g_checkpoint_requested{false};
std::atomic<unsigned int> g_checkpoint_request_frame{0};
std::atomic<unsigned long long> g_last_committed_frame{0};
std::atomic<bool> g_have_committed_frame{false};
bool g_shutdown_registered = false;
uintptr_t native_window_handle();

void queue_checkpoint(unsigned int earliest_frame) {
#ifdef SSV_VISUAL_NO_SAVE
    (void)earliest_frame;
#else
    g_checkpoint_request_frame.store(earliest_frame,
                                     std::memory_order_release);
    g_checkpoint_requested.store(true, std::memory_order_release);
    std::printf("SSV_VISUAL_CHECKPOINT_QUEUED after_frame=%u\n",
                earliest_frame);
    std::fflush(stdout);
#endif
}

int env_int(const char* name, int fallback) {
    const char* value = std::getenv(name);
    if (!value || !*value) return fallback;
    char* end = nullptr;
    const long parsed = std::strtol(value, &end, 10);
    return end && !*end ? int(parsed) : fallback;
}

int env_int_range(const char* name, int fallback, int minimum, int maximum) {
    return std::clamp(env_int(name, fallback), minimum, maximum);
}

const char* env_string(const char* name, const char* fallback = "") {
    const char* value = std::getenv(name);
    return value && *value ? value : fallback;
}

void init_lockstep_path() {
    if (g_lockstep_initialized) return;
    g_lockstep_initialized = true;
    const char* value = std::getenv("SSV_LOCKSTEP_DIR");
    if (value && *value) g_lockstep_dir = std::filesystem::path(value);
    value = std::getenv("SSV_RTL_INPUT_JOURNAL_DIR");
    if (value && *value) g_input_journal_dir = std::filesystem::path(value);
    g_lockstep_trace_start_frame = std::max(0, env_int("SSV_LOCKSTEP_START_FRAME", 0));
}

bool atomic_file(const std::filesystem::path& target, const std::string& data) {
    const auto temporary = std::filesystem::path(target.string() + ".tmp");
    std::error_code error;
    if (!target.parent_path().empty())
        std::filesystem::create_directories(target.parent_path(), error);
    {
        std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
        if (!stream) return false;
        stream.write(data.data(), std::streamsize(data.size()));
        stream.flush();
        if (!stream) return false;
    }
    for (int attempt = 0; attempt < 20; ++attempt) {
        error.clear();
        std::filesystem::remove(target, error);
        error.clear();
        std::filesystem::rename(temporary, target, error);
        if (!error) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    std::fprintf(stderr, "SSV_LOCKSTEP_ERROR rename %s\n",
                 target.string().c_str());
    return false;
}

void request_session_stop(const char* reason) {
    if (g_lockstep_dir.empty()) return;
    atomic_file(g_lockstep_dir / "STOP.txt", std::string(reason) + "\n");
}

bool read_release(long long& released) {
    if (g_lockstep_dir.empty()) return false;
    std::ifstream stream(g_lockstep_dir / "release_frame.txt", std::ios::binary);
    long long value = 0;
    if (!(stream >> value)) return false;
    released = value;
    return true;
}

bool session_stop_requested() {
    return !g_lockstep_dir.empty() &&
           std::filesystem::exists(g_lockstep_dir / "STOP.txt");
}

std::string lockstep_frame_name(const char* side, unsigned int frame) {
    char name[80];
    std::snprintf(name, sizeof(name), "%s/frame_%06u.ppm", side, frame);
    return name;
}

bool write_lockstep_ppm(unsigned int frame) {
    std::string data;
    data.reserve(32 + size_t(g_width) * size_t(g_height) * 3);
    data += "P6\n" + std::to_string(g_width) + " " +
            std::to_string(g_height) + "\n255\n";
    for (int index = 0; index < g_width * g_height; ++index) {
        const uint32_t pixel = g_pixels[index];
        data.push_back(char((pixel >> 16) & 0xff));
        data.push_back(char((pixel >> 8) & 0xff));
        data.push_back(char(pixel & 0xff));
    }
    return atomic_file(g_lockstep_dir / lockstep_frame_name("rtl", frame), data);
}

bool write_owner_input(const std::filesystem::path& directory,
                       unsigned int completed_frame, unsigned int p1_pressed,
                       unsigned int p2_pressed,
                       unsigned int system_pressed) {
    char name[80];
    // apply_inputs(completed_frame) ran immediately before this DPI commit;
    // those masks govern the next native interval, so a frame-849 checkpoint
    // owns packet 850 for the cold-reference replay.
    std::snprintf(name, sizeof(name), "inputs/frame_%06u.json",
                  completed_frame + 1);
    std::ostringstream json;
    json << "{\"frame\":" << completed_frame + 1
         << ",\"p1_pressed\":" << (p1_pressed & 0xffffu)
         << ",\"p2_pressed\":" << (p2_pressed & 0xffffu)
         << ",\"system_pressed\":" << (system_pressed & 0xffffu)
         << ",\"source\":\"rtl-owner\"}\n";
    const std::filesystem::path target =
        directory / std::filesystem::path(name).filename();
    if (std::filesystem::exists(target)) {
        std::ifstream stream(target, std::ios::binary);
        const std::string existing((std::istreambuf_iterator<char>(stream)),
                                   std::istreambuf_iterator<char>());
        if (stream && existing == json.str()) return true;
        std::fprintf(stderr,
                     "SSV_INPUT_JOURNAL_ERROR immutable packet differs path=%s\n",
                     target.string().c_str());
        return false;
    }
    return atomic_file(target, json.str());
}

void write_lockstep_ready() {
    if (g_lockstep_dir.empty() || g_lockstep_ready) return;
    const std::string set_name = env_string("SSV_LOCKSTEP_SET");
    const std::string startup_mode =
        env_string("SSV_LOCKSTEP_RTL_STARTUP_MODE", "cold-lockstep");
    int first_comparable_token =
        env_int("SSV_LOCKSTEP_FIRST_COMPARABLE_TOKEN", 1);
    if (first_comparable_token < 1) first_comparable_token = 1;
    std::ostringstream warmup;
    warmup << '[';
    for (int token = 0; token < first_comparable_token; ++token) {
        if (token) warmup << ',';
        warmup << token;
    }
    warmup << ']';
    std::ostringstream json;
    json << "{\"schema\":\"ssv-lockstep-ready-v2\","
         << "\"producer\":\"rtl\",\"set\":\""
         << set_name << "\","
         << "\"geometry\":[" << g_width << ',' << g_height << "],"
         << "\"dips\":{\"DSW1\":" << env_int("SSV_LOCKSTEP_DSW1", 255)
         << ",\"DSW2\":" << env_int("SSV_LOCKSTEP_DSW2", 255) << "},"
         << "\"sound_enabled\":true,\"input_role\":\"owner\","
         << "\"audio_capture\":true,"
         << "\"raw_frame_format\":\"P6-RGB24\","
         << "\"epoch\":\"accepted-write:21000e:low-byte:data-bit7\","
         << "\"first_complete_token\":1,"
         << "\"first_comparable_token\":" << first_comparable_token << ','
         << "\"warmup_excluded_tokens\":" << warmup.str() << ','
         << "\"capture_start_token\":" << g_lockstep_trace_start_frame << ','
         << "\"startup_mode\":\"" << startup_mode << "\",";
    if (startup_mode == "checkpoint-restore")
        json << "\"restore_committed_frame\":"
             << env_int("SSV_LOCKSTEP_RESTORE_FRAME", -1) << ',';
    json << "\"frame_boundary\":\"completed post-video-enable native surface before SDL scaling\","
         << "\"window_handle\":" << native_window_handle()
         << ",\"window_flags\":" << SDL_GetWindowFlags(g_window) << "}\n";
    std::error_code error;
    std::filesystem::remove(g_lockstep_dir / "rtl_state.jsonl", error);
    error.clear();
    std::filesystem::remove(g_lockstep_dir / "rtl_trace.jsonl", error);
    g_lockstep_ready = atomic_file(g_lockstep_dir / "rtl_ready.json", json.str());
}

void shutdown_audio() {
    if (g_audio_stream) {
        SDL_FreeAudioStream(g_audio_stream);
        g_audio_stream = nullptr;
    }
    if (g_audio_device) {
        const Uint32 queued = SDL_GetQueuedAudioSize(g_audio_device);
        std::printf(
            "SSV_VISUAL_AUDIO_CLOSE source_samples=%llu nonzero=%llu queued_frames=%llu queue_bytes=%u highwater=%u dropped_frames=%llu underflows=%llu resets=%llu reconfigs=%llu errors=%llu\n",
            static_cast<unsigned long long>(g_audio_source_samples),
            static_cast<unsigned long long>(g_audio_nonzero_samples),
            static_cast<unsigned long long>(g_audio_queued_frames), queued,
            g_audio_queue_highwater,
            static_cast<unsigned long long>(g_audio_dropped_frames),
            static_cast<unsigned long long>(g_audio_underflows),
            static_cast<unsigned long long>(g_audio_queue_resets),
            static_cast<unsigned long long>(g_audio_stream_reconfigs),
            static_cast<unsigned long long>(g_audio_errors));
        SDL_PauseAudioDevice(g_audio_device, 1);
        SDL_ClearQueuedAudio(g_audio_device);
        SDL_CloseAudioDevice(g_audio_device);
        g_audio_device = 0;
        std::fflush(stdout);
    }
    if (SDL_WasInit(SDL_INIT_AUDIO)) SDL_QuitSubSystem(SDL_INIT_AUDIO);
}

bool init_audio() {
    if (SDL_InitSubSystem(SDL_INIT_AUDIO) != 0) {
        std::fprintf(stderr, "SSV_VISUAL_AUDIO_WARNING SDL audio init: %s\n",
                     SDL_GetError());
        return false;
    }

    g_audio_output_rate =
        env_int_range("SSV_VISUAL_AUDIO_RATE", 48000, 8000, 192000);
    const int prime_ms =
        env_int_range("SSV_VISUAL_AUDIO_PRIME_MS", 40, 5, 500);
    const int max_queue_ms =
        env_int_range("SSV_VISUAL_AUDIO_MAX_QUEUE_MS", 250, 20, 2000);
    if (prime_ms >= max_queue_ms) {
        std::fprintf(stderr,
                     "SSV_VISUAL_AUDIO_WARNING prime_ms=%d must be below max_queue_ms=%d\n",
                     prime_ms, max_queue_ms);
        return false;
    }

    SDL_AudioSpec desired{};
    SDL_AudioSpec obtained{};
    desired.freq = g_audio_output_rate;
    desired.format = AUDIO_S16SYS;
    desired.channels = 2;
    desired.samples = 1024;
    desired.callback = nullptr;
    g_audio_device = SDL_OpenAudioDevice(nullptr, 0, &desired, &obtained, 0);
    if (!g_audio_device) {
        std::fprintf(stderr, "SSV_VISUAL_AUDIO_WARNING open device: %s\n",
                     SDL_GetError());
        return false;
    }
    if (obtained.format != AUDIO_S16SYS || obtained.channels != 2 ||
        obtained.freq != g_audio_output_rate) {
        std::fprintf(stderr,
                     "SSV_VISUAL_AUDIO_WARNING unexpected device format rate=%d format=0x%x channels=%u\n",
                     obtained.freq, obtained.format, obtained.channels);
        SDL_CloseAudioDevice(g_audio_device);
        g_audio_device = 0;
        return false;
    }

    constexpr Uint32 bytes_per_frame = sizeof(int16_t) * 2;
    g_audio_prime_bytes = Uint32(
        (uint64_t(g_audio_output_rate) * bytes_per_frame * prime_ms) / 1000);
    g_audio_max_queue_bytes = Uint32(
        (uint64_t(g_audio_output_rate) * bytes_per_frame * max_queue_ms) / 1000);
    g_audio_prime_bytes = std::max(bytes_per_frame,
                                   g_audio_prime_bytes & ~Uint32(3));
    g_audio_max_queue_bytes = std::max(g_audio_prime_bytes + bytes_per_frame,
                                       g_audio_max_queue_bytes & ~Uint32(3));
    SDL_PauseAudioDevice(g_audio_device, 1);
    std::printf(
        "SSV_VISUAL_AUDIO_OPEN driver=%s output_rate=%d format=S16SYS channels=2 prime_bytes=%u max_queue_bytes=%u\n",
        SDL_GetCurrentAudioDriver(), g_audio_output_rate,
        g_audio_prime_bytes, g_audio_max_queue_bytes);
    std::fflush(stdout);
    return true;
}

bool configure_audio_stream(int source_rate) {
    source_rate = std::clamp(source_rate, 1000, 1000000);
    if (g_audio_stream && source_rate == g_audio_source_rate) return true;
    if (g_audio_stream) {
        SDL_FreeAudioStream(g_audio_stream);
        g_audio_stream = nullptr;
        ++g_audio_stream_reconfigs;
    }
    g_audio_source_rate = source_rate;
    g_audio_stream = SDL_NewAudioStream(
        AUDIO_S16SYS, 2, source_rate,
        AUDIO_S16SYS, 2, g_audio_output_rate);
    if (!g_audio_stream) {
        ++g_audio_errors;
        std::fprintf(stderr,
                     "SSV_VISUAL_AUDIO_WARNING stream source_rate=%d: %s\n",
                     source_rate, SDL_GetError());
        return false;
    }
    std::printf("SSV_VISUAL_AUDIO_RATE source_rate=%d output_rate=%d reconfigs=%llu\n",
                source_rate, g_audio_output_rate,
                static_cast<unsigned long long>(g_audio_stream_reconfigs));
    std::fflush(stdout);
    return true;
}

void queue_output_audio(const uint8_t* data, Uint32 bytes) {
    if (!g_audio_device || bytes == 0) return;
    constexpr Uint32 bytes_per_frame = sizeof(int16_t) * 2;
    Uint32 queued = SDL_GetQueuedAudioSize(g_audio_device);
    if (g_audio_started && queued == 0) {
        ++g_audio_underflows;
        g_audio_started = false;
        SDL_PauseAudioDevice(g_audio_device, 1);
    }
    if (queued + bytes > g_audio_max_queue_bytes) {
        g_audio_dropped_frames += queued / bytes_per_frame;
        ++g_audio_queue_resets;
        SDL_ClearQueuedAudio(g_audio_device);
        SDL_PauseAudioDevice(g_audio_device, 1);
        g_audio_started = false;
        queued = 0;
    }
    if (SDL_QueueAudio(g_audio_device, data, bytes) != 0) {
        ++g_audio_errors;
        if (g_audio_errors <= 8)
            std::fprintf(stderr, "SSV_VISUAL_AUDIO_WARNING queue: %s\n",
                         SDL_GetError());
        return;
    }
    g_audio_queued_frames += bytes / bytes_per_frame;
    queued += bytes;
    g_audio_queue_highwater = std::max(g_audio_queue_highwater, queued);
    if (!g_audio_started && queued >= g_audio_prime_bytes) {
        SDL_PauseAudioDevice(g_audio_device, 0);
        g_audio_started = true;
    }
}

void submit_audio_sample(int sample_l, int sample_r, unsigned int source_rate) {
    ++g_audio_source_samples;
    if (sample_l != 0 || sample_r != 0) ++g_audio_nonzero_samples;
    if (!g_audio_device) return;
    if (!configure_audio_stream(int(source_rate))) return;

    const int16_t frame[2] = {
        static_cast<int16_t>(sample_l), static_cast<int16_t>(sample_r)
    };
    if (SDL_AudioStreamPut(g_audio_stream, frame, sizeof(frame)) != 0) {
        ++g_audio_errors;
        if (g_audio_errors <= 8)
            std::fprintf(stderr, "SSV_VISUAL_AUDIO_WARNING stream put: %s\n",
                         SDL_GetError());
        return;
    }

    std::array<uint8_t, 4096> converted{};
    int available = SDL_AudioStreamAvailable(g_audio_stream);
    while (available > 0) {
        const int request = std::min(available, int(converted.size()));
        const int received = SDL_AudioStreamGet(
            g_audio_stream, converted.data(), request);
        if (received <= 0) {
            if (received < 0) {
                ++g_audio_errors;
                std::fprintf(stderr,
                             "SSV_VISUAL_AUDIO_WARNING stream get: %s\n",
                             SDL_GetError());
            }
            break;
        }
        queue_output_audio(converted.data(), Uint32(received));
        available = SDL_AudioStreamAvailable(g_audio_stream);
    }

    if (g_audio_source_samples <= 8 ||
        (g_audio_source_samples % 8192) == 0) {
        std::printf(
            "SSV_VISUAL_AUDIO_SAMPLE seq=%llu source_rate=%u left=%d right=%d nonzero=%llu queue_bytes=%u queued_frames=%llu dropped_frames=%llu underflows=%llu resets=%llu\n",
            static_cast<unsigned long long>(g_audio_source_samples),
            source_rate, sample_l, sample_r,
            static_cast<unsigned long long>(g_audio_nonzero_samples),
            SDL_GetQueuedAudioSize(g_audio_device),
            static_cast<unsigned long long>(g_audio_queued_frames),
            static_cast<unsigned long long>(g_audio_dropped_frames),
            static_cast<unsigned long long>(g_audio_underflows),
            static_cast<unsigned long long>(g_audio_queue_resets));
        std::fflush(stdout);
    }
}

uintptr_t native_window_handle() {
    if (!g_window) return 0;
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(g_window, &info)) return 0;
#if defined(_WIN32)
    return reinterpret_cast<uintptr_t>(info.info.win.window);
#else
    return 0;
#endif
}

void shutdown_sdl() {
    shutdown_audio();
    if (g_controller) SDL_GameControllerClose(g_controller);
    if (g_texture) SDL_DestroyTexture(g_texture);
    if (g_renderer) SDL_DestroyRenderer(g_renderer);
    if (g_window) SDL_DestroyWindow(g_window);
    g_controller = nullptr;
    g_texture = nullptr;
    g_renderer = nullptr;
    g_window = nullptr;
    SDL_Quit();
}

bool init_sdl() {
    if (g_window) return true;
    init_lockstep_path();
    SDL_SetMainReady();
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER) != 0) {
        std::fprintf(stderr, "SSV_VISUAL_ERROR SDL_Init: %s\n", SDL_GetError());
        return false;
    }
    if (!g_shutdown_registered) {
        std::atexit(shutdown_sdl);
        g_shutdown_registered = true;
    }
#ifdef SSV_VISUAL_NO_SAVE
    g_window = SDL_CreateWindow(
        "SSV Verilator | booting | NO FULL-STATE SAVE",
#else
    g_window = SDL_CreateWindow(
        "SSV Verilator | booting | checkpoint ready",
#endif
        env_int("SSV_WINDOW_X", SDL_WINDOWPOS_CENTERED),
        env_int("SSV_WINDOW_Y", SDL_WINDOWPOS_CENTERED),
        env_int("SSV_WINDOW_W", kMaxWidth * 3),
        env_int("SSV_WINDOW_H", kMaxHeight * 3),
        SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
    if (!g_window) {
        std::fprintf(stderr, "SSV_VISUAL_ERROR SDL_CreateWindow: %s\n", SDL_GetError());
        return false;
    }
    g_renderer = SDL_CreateRenderer(
        g_window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!g_renderer)
        g_renderer = SDL_CreateRenderer(g_window, -1, SDL_RENDERER_SOFTWARE);
    if (!g_renderer) {
        std::fprintf(stderr, "SSV_VISUAL_ERROR SDL_CreateRenderer: %s\n", SDL_GetError());
        return false;
    }
    SDL_RenderSetLogicalSize(g_renderer, g_width, g_height);
    if (SDL_RenderSetIntegerScale(g_renderer, SDL_TRUE) != 0)
        std::fprintf(stderr, "SSV_VISUAL_WARNING integer scale: %s\n", SDL_GetError());
    g_texture = SDL_CreateTexture(g_renderer, SDL_PIXELFORMAT_ARGB8888,
                                  SDL_TEXTUREACCESS_STREAMING,
                                  g_width, g_height);
    if (!g_texture) {
        std::fprintf(stderr, "SSV_VISUAL_ERROR SDL_CreateTexture: %s\n", SDL_GetError());
        return false;
    }
    init_audio();
    for (int index = 0; index < SDL_NumJoysticks(); ++index) {
        if (SDL_IsGameController(index)) {
            g_controller = SDL_GameControllerOpen(index);
            if (g_controller) break;
        }
    }
    std::puts("SSV_VISUAL_WINDOW_OPEN max=352x240 nearest integer-scale");
    std::printf("SSV_VISUAL_NATIVE driver=%s hwnd=0x%llx flags=0x%x\n",
                SDL_GetCurrentVideoDriver(),
                static_cast<unsigned long long>(native_window_handle()),
                SDL_GetWindowFlags(g_window));
    std::puts("SSV_VISUAL_CONTROLS arrows=move Z/X/C=B1/B2/B3 Enter=start 5=coin Esc=quit F12=screenshot");
#ifdef SSV_VISUAL_NO_SAVE
    std::puts("SSV_VISUAL_NO_SAVE timing model: F5/Ctrl+S full-state checkpoint unavailable");
#else
    std::puts("SSV_VISUAL_CHECKPOINT controls=F5/Ctrl+S boundary=completed-native-frame");
#endif
    std::fflush(stdout);
    return true;
}

bool save_bmp(const std::filesystem::path& target) {
    SDL_Surface* surface = SDL_CreateRGBSurfaceWithFormatFrom(
        g_pixels.data(), g_width, g_height, 32, g_width * 4,
        SDL_PIXELFORMAT_ARGB8888);
    if (!surface) return false;
    std::error_code error;
    if (!target.parent_path().empty())
        std::filesystem::create_directories(target.parent_path(), error);
    const int result = SDL_SaveBMP(surface, target.string().c_str());
    SDL_FreeSurface(surface);
    if (result != 0) {
        std::fprintf(stderr, "SSV_VISUAL_ERROR SDL_SaveBMP: %s\n", SDL_GetError());
        return false;
    }
    return true;
}

void capture_latest(unsigned int frame, bool forced) {
    const char* value = std::getenv("SSV_VISUAL_SCREENSHOT");
    if (!value || !*value || !g_have_frame) return;
    const auto now = std::chrono::steady_clock::now();
    if (!forced && g_have_capture &&
        now - g_last_capture < std::chrono::seconds(30)) return;
    g_have_capture = true;
    g_last_capture = now;
    if (save_bmp(std::filesystem::path(value))) {
        std::printf("SSV_VISUAL_SCREENSHOT frame=%u path=%s\n", frame, value);
        std::fflush(stdout);
    }
}

void poll_events(unsigned int frame, bool sample_controls = true) {
    SDL_Event event;
    bool force_capture = false;
    while (SDL_PollEvent(&event)) {
        if (event.type == SDL_QUIT) {
            std::puts("SSV_VISUAL_EVENT window-close");
            std::fflush(stdout);
            g_quit = true;
            request_session_stop("RTL window closed");
        }
        if (event.type == SDL_CONTROLLERDEVICEADDED && !g_controller)
            g_controller = SDL_GameControllerOpen(event.cdevice.which);
        if (event.type == SDL_CONTROLLERDEVICEREMOVED && g_controller &&
            SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(g_controller)) ==
                event.cdevice.which) {
            SDL_GameControllerClose(g_controller);
            g_controller = nullptr;
        }
        if (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE) {
            std::puts("SSV_VISUAL_EVENT escape");
            std::fflush(stdout);
            g_quit = true;
            request_session_stop("RTL escape requested");
        }
        if (event.type == SDL_KEYDOWN && !event.key.repeat &&
            event.key.keysym.sym == SDLK_F12)
            force_capture = true;
        if (event.type == SDL_KEYDOWN && !event.key.repeat &&
            (event.key.keysym.sym == SDLK_F5 ||
             (event.key.keysym.sym == SDLK_s &&
              (event.key.keysym.mod & KMOD_CTRL)))) {
#ifdef SSV_VISUAL_NO_SAVE
            std::puts("SSV_VISUAL_NO_SAVE full-state checkpoint unavailable in this timing profile");
            std::fflush(stdout);
#else
            queue_checkpoint(frame);
#endif
        }
    }

    if (!sample_controls) {
        if (force_capture) capture_latest(frame, true);
        return;
    }
    g_p1 = 0;
    g_system = 0;
    const bool focused = SDL_GetKeyboardFocus() == g_window;
    const uint8_t* keys = SDL_GetKeyboardState(nullptr);
    if (focused && keys[SDL_SCANCODE_UP]) g_p1 |= 1u << 7;
    if (focused && keys[SDL_SCANCODE_DOWN]) g_p1 |= 1u << 6;
    if (focused && keys[SDL_SCANCODE_LEFT]) g_p1 |= 1u << 5;
    if (focused && keys[SDL_SCANCODE_RIGHT]) g_p1 |= 1u << 4;
    if (focused && keys[SDL_SCANCODE_Z]) g_p1 |= 1u << 3;
    if (focused && keys[SDL_SCANCODE_X]) g_p1 |= 1u << 2;
    if (focused && keys[SDL_SCANCODE_C]) g_p1 |= 1u << 1;
    if (focused && keys[SDL_SCANCODE_RETURN]) g_p1 |= 1u << 0;
    if (focused && keys[SDL_SCANCODE_5]) g_system |= 1u << 0;

    if (g_controller && SDL_GameControllerGetAttached(g_controller)) {
        if (SDL_GameControllerGetButton(g_controller, SDL_CONTROLLER_BUTTON_DPAD_UP)) g_p1 |= 1u << 7;
        if (SDL_GameControllerGetButton(g_controller, SDL_CONTROLLER_BUTTON_DPAD_DOWN)) g_p1 |= 1u << 6;
        if (SDL_GameControllerGetButton(g_controller, SDL_CONTROLLER_BUTTON_DPAD_LEFT)) g_p1 |= 1u << 5;
        if (SDL_GameControllerGetButton(g_controller, SDL_CONTROLLER_BUTTON_DPAD_RIGHT)) g_p1 |= 1u << 4;
        if (SDL_GameControllerGetButton(g_controller, SDL_CONTROLLER_BUTTON_X)) g_p1 |= 1u << 3;
        if (SDL_GameControllerGetButton(g_controller, SDL_CONTROLLER_BUTTON_A)) g_p1 |= 1u << 2;
        if (SDL_GameControllerGetButton(g_controller, SDL_CONTROLLER_BUTTON_B)) g_p1 |= 1u << 1;
        if (SDL_GameControllerGetButton(g_controller, SDL_CONTROLLER_BUTTON_START)) g_p1 |= 1u << 0;
        if (SDL_GameControllerGetButton(g_controller, SDL_CONTROLLER_BUTTON_BACK)) g_system |= 1u << 0;
    }
    if (force_capture) capture_latest(frame, true);
}

bool lockstep_publish_and_wait(unsigned int frame, unsigned int p1_pressed,
                               unsigned int p2_pressed,
                               unsigned int system_pressed,
                               unsigned int pc, unsigned int list512_crc,
                               unsigned int spr8k_crc,
                               unsigned int scroll63_crc,
                               unsigned int pal512_crc,
                               unsigned int st010_present,
                               unsigned int st010_pc, unsigned int st010_a,
                               unsigned int st010_b, unsigned int st010_dp,
                               unsigned int st010_dr, unsigned int st010_k,
                               unsigned int st010_l, unsigned int st010_m,
                               unsigned int st010_n) {
    init_lockstep_path();
    const bool complete_surface =
        g_pending_frame == static_cast<long long>(frame);
    if (!complete_surface) {
        std::printf("SSV_LOCKSTEP_SKIP_INCOMPLETE frame=%u pending=%lld\n",
                    frame, g_pending_frame);
        std::fflush(stdout);
        if (g_lockstep_dir.empty() && g_input_journal_dir.empty())
            return true;
        if (!g_lockstep_dir.empty() &&
            frame >= static_cast<unsigned int>(g_lockstep_trace_start_frame)) {
            request_session_stop("unexpected incomplete RTL frame");
            return false;
        }
        // A video-enable epoch can begin part-way through the raster, so an
        // excluded warm-up token is not guaranteed to own a complete native
        // surface.  It still owns the next immutable input packet and must
        // cross the two-producer barrier.  Publish the token without a frame,
        // state, or trace artifact; the coordinator never compares excluded
        // warm-up surfaces.
    }
    // write_owner_input records the packet for the interval after this
    // completed/excluded surface (N -> N+1).  Thus external-clock warm-up
    // frame zero owns packet 1 without overwriting the neutral packet zero.
    if (!g_input_journal_dir.empty() &&
        !write_owner_input(g_input_journal_dir, frame, p1_pressed,
                           p2_pressed, system_pressed)) {
        request_session_stop("RTL input journal publication failed");
        return false;
    }
    if (g_lockstep_dir.empty()) {
        g_pending_frame = -1;
        return true;
    }
    write_lockstep_ready();
    const bool capture_frame = complete_surface &&
        frame >= static_cast<unsigned int>(g_lockstep_trace_start_frame);
    if ((capture_frame && !write_lockstep_ppm(frame)) ||
        !write_owner_input(g_lockstep_dir / "inputs", frame, p1_pressed,
                           p2_pressed, system_pressed)) {
        request_session_stop("RTL capture publication failed");
        return false;
    }
    if (capture_frame) {
        {
            std::ofstream state(g_lockstep_dir / "rtl_state.jsonl",
                                std::ios::binary | std::ios::app);
            state << "{\"frame\":" << frame << ",\"producer\":\"rtl\","
                  << "\"pc\":" << pc << ",\"list512_crc\":" << list512_crc
                  << ",\"spr8k_crc\":" << spr8k_crc
                  << ",\"scroll63_crc\":" << scroll63_crc
                  << ",\"pal512_crc\":" << pal512_crc;
            if (st010_present) {
                state << ",\"st010_pc\":" << st010_pc
                      << ",\"st010_a\":" << st010_a
                      << ",\"st010_b\":" << st010_b
                      << ",\"st010_dp\":" << st010_dp
                      << ",\"st010_dr\":" << st010_dr
                      << ",\"st010_k\":" << st010_k
                      << ",\"st010_l\":" << st010_l
                      << ",\"st010_m\":" << st010_m
                      << ",\"st010_n\":" << st010_n;
            }
            state << "}\n";
            state.flush();
            if (!state) {
                request_session_stop("RTL state publication failed");
                return false;
            }
        }
        if (!g_lockstep_trace_buffer.empty()) {
            std::ofstream trace(g_lockstep_dir / "rtl_trace.jsonl",
                                std::ios::binary | std::ios::app);
            trace.write(g_lockstep_trace_buffer.data(),
                        std::streamsize(g_lockstep_trace_buffer.size()));
            trace.flush();
            g_lockstep_trace_buffer.clear();
            if (!trace) {
                request_session_stop("RTL trace publication failed");
                return false;
            }
        }
    }
    if (!atomic_file(g_lockstep_dir / "rtl_frame.txt",
                     std::to_string(frame) + "\n")) {
        request_session_stop("RTL frame token publication failed");
        return false;
    }
    g_pending_frame = -1;
    for (;;) {
        if (session_stop_requested()) return false;
        long long released = -1;
        if (read_release(released) && released >= static_cast<long long>(frame)) {
            if (std::filesystem::exists(g_lockstep_dir / "TRACE_STOP.txt"))
                g_lockstep_trace_stopped = true;
            return true;
        }
        poll_events(frame, false);
        if (g_quit) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}

uint32_t checksum_pixels() {
    uint32_t hash = 2166136261u;
    const int pixel_count = g_width * g_height;
    for (int index = 0; index < pixel_count; ++index) {
        const uint32_t pixel = g_pixels[index];
        hash ^= pixel;
        hash *= 16777619u;
    }
    return hash;
}

void write_status(unsigned int frame, uint32_t checksum,
                  size_t changed_pixels, size_t nonblack) {
    const char* value = std::getenv("SSV_VISUAL_STATUS");
    if (!value || !*value) return;
    const std::filesystem::path target(value);
    const std::filesystem::path temporary = target.string() + ".tmp";
    std::error_code error;
    if (!target.parent_path().empty())
        std::filesystem::create_directories(target.parent_path(), error);
    {
        std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
        const uintptr_t native_handle = native_window_handle();
        stream << frame << ' ' << checksum << ' ' << g_checksum_changes << ' '
               << changed_pixels << ' ' << nonblack << ' ' << g_width << ' '
               << g_height << ' ' << native_handle << ' '
               << SDL_GetWindowFlags(g_window) << '\n';
    }
    std::filesystem::remove(target, error);
    error.clear();
    std::filesystem::rename(temporary, target, error);
    if (error)
        std::fprintf(stderr, "SSV_VISUAL_WARNING status rename: %s\n",
                     error.message().c_str());
}

void reset_process_local_state_after_restore() {
    g_audio_output_rate = 48000;
    g_audio_source_rate = 0;
    g_audio_prime_bytes = 0;
    g_audio_max_queue_bytes = 0;
    g_audio_queue_highwater = 0;
    g_audio_started = false;
    g_audio_source_samples = 0;
    g_audio_nonzero_samples = 0;
    g_audio_queued_frames = 0;
    g_audio_dropped_frames = 0;
    g_audio_underflows = 0;
    g_audio_queue_resets = 0;
    g_audio_stream_reconfigs = 0;
    g_audio_errors = 0;
    g_p1 = 0;
    g_system = 0;
    g_quit = false;
    g_have_frame = false;
    g_previous_checksum = 0;
    g_checksum_changes = 0;
    g_have_capture = false;
    g_pending_frame = -1;
    g_lockstep_ready = false;
    g_lockstep_trace_stopped = false;
    g_lockstep_trace_buffer.clear();
    g_checkpoint_requested.store(false, std::memory_order_release);
    g_checkpoint_request_frame.store(0, std::memory_order_release);
    g_last_committed_frame.store(0, std::memory_order_release);
    g_have_committed_frame.store(false, std::memory_order_release);
    g_pixels.fill(0xff000000u);
    g_previous.fill(0xff000000u);
}
}

extern "C" int ssv_visual_present(const svBitVecVal* pixels,
                                  unsigned int width,
                                  unsigned int height,
                                  unsigned int raster_frame) {
    if (!g_window && !init_sdl()) return 1;
    if (width < 1 || width > kMaxWidth || height < 1 || height > kMaxHeight) {
        std::fprintf(stderr, "SSV_VISUAL_ERROR dimensions=%ux%u max=%dx%d\n",
                     width, height, kMaxWidth, kMaxHeight);
        return 1;
    }
    if (g_width != int(width) || g_height != int(height)) {
        g_width = int(width);
        g_height = int(height);
        SDL_DestroyTexture(g_texture);
        g_texture = SDL_CreateTexture(g_renderer, SDL_PIXELFORMAT_ARGB8888,
                                      SDL_TEXTUREACCESS_STREAMING,
                                      g_width, g_height);
        if (!g_texture) {
            std::fprintf(stderr, "SSV_VISUAL_ERROR resize texture: %s\n",
                         SDL_GetError());
            return 1;
        }
        SDL_RenderSetLogicalSize(g_renderer, g_width, g_height);
        SDL_RenderSetIntegerScale(g_renderer, SDL_TRUE);
        g_have_frame = false;
        g_previous.fill(0);
    }
    poll_events(raster_frame);
    size_t changed_pixels = 0;
    size_t nonblack = 0;
    const int pixel_count = g_width * g_height;
    for (int index = 0; index < pixel_count; ++index) {
        const uint32_t pixel = 0xff000000u | (pixels[index] & 0x00ffffffu);
        g_pixels[index] = pixel;
        changed_pixels += pixel != g_previous[index];
        nonblack += (pixel & 0x00ffffffu) != 0;
    }
    const uint32_t checksum = checksum_pixels();
    if (g_have_frame && checksum != g_previous_checksum) ++g_checksum_changes;
    g_previous_checksum = checksum;
    g_previous = g_pixels;
    g_have_frame = true;
    g_pending_frame = raster_frame;

    SDL_UpdateTexture(g_texture, nullptr, g_pixels.data(), g_width * 4);
    SDL_SetRenderDrawColor(g_renderer, 0, 0, 0, 255);
    SDL_RenderClear(g_renderer);
    SDL_RenderCopy(g_renderer, g_texture, nullptr, nullptr);
    SDL_RenderPresent(g_renderer);
    capture_latest(raster_frame, false);

    char title[224];
#ifdef SSV_VISUAL_NO_SAVE
    std::snprintf(title, sizeof(title),
                  "SSV Verilator | %dx%d | frame %u | checksum %08x | changes %llu | pixels %zu | NO SAVE",
                  g_width, g_height, raster_frame, checksum,
                  static_cast<unsigned long long>(g_checksum_changes),
                  changed_pixels);
#else
    std::snprintf(title, sizeof(title),
                  "SSV Verilator | %dx%d | frame %u | checksum %08x | changes %llu | pixels %zu | checkpoint %s",
                  g_width, g_height, raster_frame, checksum,
                  static_cast<unsigned long long>(g_checksum_changes),
                  changed_pixels,
                  g_checkpoint_requested.load(std::memory_order_acquire)
                      ? "queued" : "ready");
#endif
    SDL_SetWindowTitle(g_window, title);
    write_status(raster_frame, checksum, changed_pixels, nonblack);
    std::printf("SSV_VISUAL_FRAME size=%dx%d frame=%u checksum=%08x changes=%llu changed_pixels=%zu nonblack=%zu\n",
                g_width, g_height, raster_frame, checksum,
                static_cast<unsigned long long>(g_checksum_changes),
                changed_pixels, nonblack);
    std::fflush(stdout);
    return g_quit ? 1 : 0;
}

extern "C" void ssv_visual_set_geometry(unsigned int width,
                                         unsigned int height) {
    if (g_window) return;
    if (width >= 1 && width <= kMaxWidth) g_width = static_cast<int>(width);
    if (height >= 1 && height <= kMaxHeight)
        g_height = static_cast<int>(height);
}

extern "C" int ssv_visual_init() { return init_sdl() ? 0 : 1; }
extern "C" int ssv_visual_poll() {
    if (!g_window && !init_sdl()) return 1;
    poll_events(0, true);
    return g_quit ? 1 : 0;
}
extern "C" int ssv_visual_p1() { return g_p1; }
extern "C" int ssv_visual_system() { return g_system; }
extern "C" void ssv_visual_trace_bus(
    unsigned long long frame, unsigned long long cycle, unsigned int pc,
    unsigned int write, unsigned int address, unsigned int data,
    unsigned int lanes, unsigned int device) {
    init_lockstep_path();
    if (g_lockstep_dir.empty() || g_lockstep_trace_stopped ||
        env_int("SSV_LOCKSTEP_TRACE", 1) == 0 ||
        frame < static_cast<unsigned long long>(g_lockstep_trace_start_frame)) return;
    unsigned int normalized = 0;
    if (lanes & 1u) normalized |= data & 0x00ffu;
    if (lanes & 2u) normalized |= data & 0xff00u;
    char line[320];
    const int count = std::snprintf(
        line, sizeof(line),
        "{\"frame\":%llu,\"cycle\":%llu,\"pc\":%u,\"cpu\":0,"
        "\"event\":\"bus\",\"rw\":\"%c\",\"address\":%u,"
        "\"data\":%u,\"lanes\":%u,\"device\":%u}\n",
        frame, cycle, pc, write ? 'w' : 'r', address, normalized,
        lanes & 3u, device);
    if (count > 0)
        g_lockstep_trace_buffer.append(line, size_t(std::min(count, int(sizeof(line) - 1))));
}
extern "C" int ssv_visual_frame_commit(
    unsigned int frame, unsigned int p1_pressed, unsigned int p2_pressed,
    unsigned int system_pressed, unsigned int pc, unsigned int list512_crc,
    unsigned int spr8k_crc, unsigned int scroll63_crc,
    unsigned int pal512_crc, unsigned int st010_present,
    unsigned int st010_pc, unsigned int st010_a, unsigned int st010_b,
    unsigned int st010_dp, unsigned int st010_dr, unsigned int st010_k,
    unsigned int st010_l, unsigned int st010_m, unsigned int st010_n) {
    const bool committed = lockstep_publish_and_wait(
        frame, p1_pressed, p2_pressed, system_pressed, pc, list512_crc,
        spr8k_crc, scroll63_crc, pal512_crc, st010_present, st010_pc,
        st010_a, st010_b, st010_dp, st010_dr, st010_k, st010_l, st010_m,
        st010_n);
#ifndef SSV_VISUAL_NO_SAVE
    if (committed) {
        // The external-clock main is not re-entered until this DPI function
        // returns.  Publishing here therefore defines the checkpoint-safe
        // boundary: framebuffer, evidence files and lockstep release are all
        // complete before the main thread may consume a queued request.
        g_last_committed_frame.store(frame, std::memory_order_release);
        g_have_committed_frame.store(true, std::memory_order_release);
    }
#endif
    return committed ? 0 : 1;
}
extern "C" void ssv_visual_audio_sample(int sample_l, int sample_r,
                                         unsigned int source_rate) {
    submit_audio_sample(sample_l, sample_r, source_rate);
}

extern "C" int ssv_visual_checkpoint_request_pending() {
#ifdef SSV_VISUAL_NO_SAVE
    return 0;
#else
    return g_checkpoint_requested.load(std::memory_order_acquire) ? 1 : 0;
#endif
}

extern "C" int ssv_visual_checkpoint_consume_request(
    unsigned long long* committed_frame) {
#ifdef SSV_VISUAL_NO_SAVE
    (void)committed_frame;
    return 0;
#else
    if (!g_checkpoint_requested.load(std::memory_order_acquire) ||
        !g_have_committed_frame.load(std::memory_order_acquire))
        return 0;
    const unsigned long long frame =
        g_last_committed_frame.load(std::memory_order_acquire);
    const unsigned int requested_after =
        g_checkpoint_request_frame.load(std::memory_order_acquire);
    if (frame < requested_after) return 0;
    bool expected = true;
    if (!g_checkpoint_requested.compare_exchange_strong(
            expected, false, std::memory_order_acq_rel))
        return 0;
    if (committed_frame) *committed_frame = frame;
    return 1;
#endif
}

extern "C" int ssv_visual_checkpoint_last_committed_frame(
    unsigned long long* committed_frame) {
    if (!g_have_committed_frame.load(std::memory_order_acquire)) return 0;
    if (committed_frame)
        *committed_frame =
            g_last_committed_frame.load(std::memory_order_acquire);
    return 1;
}

extern "C" void ssv_visual_checkpoint_notify_saved(
    const char* path, const char* coordinate_name,
    unsigned long long coordinate, int success) {
    std::printf("SSV_VISUAL_CHECKPOINT_%s %s=%llu path=%s\n",
                success ? "SAVED" : "FAILED",
                coordinate_name ? coordinate_name : "frame", coordinate,
                path ? path : "");
    std::fflush(stdout);
    if (g_window) {
        std::string title = success ? "SSV Verilator | checkpoint saved: "
                                    : "SSV Verilator | checkpoint FAILED: ";
        title += path ? path : "";
        SDL_SetWindowTitle(g_window, title.c_str());
    }
}

extern "C" int ssv_visual_checkpoint_after_restore() {
#ifdef SSV_VISUAL_NO_SAVE
    return 1;
#else
    // SDL handles, renderer textures, controllers, audio devices/streams and
    // queued audio are process-local and are deliberately absent from the
    // Verilated archive. Recreate them after model restore in both a fresh
    // process and any future same-process restore path.
    shutdown_sdl();
    reset_process_local_state_after_restore();
    if (!init_sdl()) return 1;
    std::puts("SSV_VISUAL_CHECKPOINT_RESTORE_HOST_READY fresh_sdl=1 fresh_audio=1");
    std::fflush(stdout);
    return 0;
#endif
}

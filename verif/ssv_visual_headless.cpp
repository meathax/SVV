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

// Non-SDL host for the protocol-v2 lockstep testbench.  It deliberately keeps
// the same DPI and frame/input/barrier semantics as ssv_visual_sdl.cpp while
// exposing no window, event loop, audio device, or display dependency.
namespace {
constexpr int kMaxWidth = 352;
constexpr int kMaxHeight = 240;
constexpr int kMaxPixels = kMaxWidth * kMaxHeight;

std::array<uint32_t, kMaxPixels> g_pixels{};
int g_width = 336;
int g_height = 240;
long long g_pending_frame = -1;
std::filesystem::path g_lockstep_dir;
std::filesystem::path g_input_journal_dir;
bool g_initialized = false;
bool g_ready = false;
bool g_trace_stopped = false;
int g_trace_start_frame = 0;
std::string g_trace_buffer;
std::atomic<unsigned long long> g_last_committed_frame{0};
std::atomic<bool> g_have_committed_frame{false};
uint64_t g_audio_samples = 0;
uint64_t g_audio_nonzero_samples = 0;

int env_int(const char* name, int fallback) {
    const char* value = std::getenv(name);
    if (!value || !*value) return fallback;
    char* end = nullptr;
    const long parsed = std::strtol(value, &end, 10);
    return end && !*end ? int(parsed) : fallback;
}

const char* env_string(const char* name, const char* fallback = "") {
    const char* value = std::getenv(name);
    return value && *value ? value : fallback;
}

void init_paths() {
    if (g_initialized) return;
    g_initialized = true;
    const char* value = std::getenv("SSV_LOCKSTEP_DIR");
    if (value && *value) g_lockstep_dir = std::filesystem::path(value);
    value = std::getenv("SSV_RTL_INPUT_JOURNAL_DIR");
    if (value && *value) g_input_journal_dir = std::filesystem::path(value);
    g_trace_start_frame = std::max(0, env_int("SSV_LOCKSTEP_START_FRAME", 0));
}

bool atomic_file(const std::filesystem::path& target, const std::string& data) {
    const std::filesystem::path temporary(target.string() + ".tmp");
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
    std::fprintf(stderr, "SSV_HEADLESS_ERROR rename path=%s\n",
                 target.string().c_str());
    return false;
}

void request_stop(const char* reason) {
    if (!g_lockstep_dir.empty())
        atomic_file(g_lockstep_dir / "STOP.txt", std::string(reason) + "\n");
}

bool stop_requested() {
    return !g_lockstep_dir.empty() &&
           std::filesystem::exists(g_lockstep_dir / "STOP.txt");
}

bool read_release(long long& released) {
    std::ifstream stream(g_lockstep_dir / "release_frame.txt", std::ios::binary);
    return bool(stream >> released);
}

bool write_owner_input(const std::filesystem::path& directory,
                       unsigned int completed_frame, unsigned int p1_pressed,
                       unsigned int p2_pressed,
                       unsigned int system_pressed) {
    char name[64];
    std::snprintf(name, sizeof(name), "frame_%06u.json", completed_frame + 1);
    std::ostringstream json;
    json << "{\"frame\":" << completed_frame + 1
         << ",\"p1_pressed\":" << (p1_pressed & 0xffffu)
         << ",\"p2_pressed\":" << (p2_pressed & 0xffffu)
         << ",\"system_pressed\":" << (system_pressed & 0xffffu)
         << ",\"source\":\"rtl-owner\"}\n";
    const auto target = directory / name;
    if (std::filesystem::exists(target)) {
        std::ifstream stream(target, std::ios::binary);
        const std::string existing((std::istreambuf_iterator<char>(stream)),
                                   std::istreambuf_iterator<char>());
        return stream && existing == json.str();
    }
    return atomic_file(target, json.str());
}

bool write_ppm(unsigned int frame) {
    char name[64];
    std::snprintf(name, sizeof(name), "frame_%06u.ppm", frame);
    std::string data = "P6\n" + std::to_string(g_width) + " " +
                       std::to_string(g_height) + "\n255\n";
    data.reserve(data.size() + size_t(g_width) * size_t(g_height) * 3);
    for (int index = 0; index < g_width * g_height; ++index) {
        const uint32_t pixel = g_pixels[index];
        data.push_back(char((pixel >> 16) & 0xff));
        data.push_back(char((pixel >> 8) & 0xff));
        data.push_back(char(pixel & 0xff));
    }
    return atomic_file(g_lockstep_dir / "rtl" / name, data);
}

void write_ready() {
    if (g_lockstep_dir.empty() || g_ready) return;
    const int first_comparable =
        std::max(1, env_int("SSV_LOCKSTEP_FIRST_COMPARABLE_TOKEN", 1));
    std::ostringstream warmup;
    warmup << '[';
    for (int token = 0; token < first_comparable; ++token) {
        if (token) warmup << ',';
        warmup << token;
    }
    warmup << ']';
    const std::string startup_mode =
        env_string("SSV_LOCKSTEP_RTL_STARTUP_MODE", "cold-lockstep");
    std::ostringstream json;
    json << "{\"schema\":\"ssv-lockstep-ready-v2\","
         << "\"producer\":\"rtl\",\"set\":\""
         << env_string("SSV_LOCKSTEP_SET") << "\","
         << "\"geometry\":[" << g_width << ',' << g_height << "],"
         << "\"dips\":{\"DSW1\":" << env_int("SSV_LOCKSTEP_DSW1", 255)
         << ",\"DSW2\":" << env_int("SSV_LOCKSTEP_DSW2", 255) << "},"
         << "\"sound_enabled\":true,\"input_role\":\"owner\","
         << "\"audio_capture\":false,\"headless\":true,"
         << "\"display_backend\":\"none\","
         << "\"raw_frame_format\":\"P6-RGB24\","
         << "\"epoch\":\"accepted-write:21000e:low-byte:data-bit7\","
         << "\"first_complete_token\":1,"
         << "\"first_comparable_token\":" << first_comparable << ','
         << "\"warmup_excluded_tokens\":" << warmup.str() << ','
         << "\"capture_start_token\":" << g_trace_start_frame << ','
         << "\"startup_mode\":\"" << startup_mode << "\",";
    if (startup_mode == "checkpoint-restore")
        json << "\"restore_committed_frame\":"
             << env_int("SSV_LOCKSTEP_RESTORE_FRAME", -1) << ',';
    json << "\"frame_boundary\":\"completed post-video-enable native surface before presentation scaling\"}\n";
    std::error_code error;
    std::filesystem::remove(g_lockstep_dir / "rtl_state.jsonl", error);
    error.clear();
    std::filesystem::remove(g_lockstep_dir / "rtl_trace.jsonl", error);
    g_ready = atomic_file(g_lockstep_dir / "rtl_ready.json", json.str());
}

bool publish_and_wait(
    unsigned int frame, unsigned int p1_pressed, unsigned int p2_pressed,
    unsigned int system_pressed, unsigned int pc, unsigned int list512_crc,
    unsigned int spr8k_crc, unsigned int scroll63_crc,
    unsigned int pal512_crc, unsigned int st010_present,
    unsigned int st010_pc, unsigned int st010_a, unsigned int st010_b,
    unsigned int st010_dp, unsigned int st010_dr, unsigned int st010_k,
    unsigned int st010_l, unsigned int st010_m, unsigned int st010_n) {
    init_paths();
    const bool complete_surface =
        g_pending_frame == static_cast<long long>(frame);
    if (!complete_surface && !g_lockstep_dir.empty() &&
        frame >= static_cast<unsigned int>(g_trace_start_frame)) {
        request_stop("unexpected incomplete RTL frame");
        return false;
    }
    if (!g_input_journal_dir.empty() &&
        !write_owner_input(g_input_journal_dir, frame, p1_pressed,
                           p2_pressed, system_pressed)) {
        request_stop("RTL input journal publication failed");
        return false;
    }
    if (g_lockstep_dir.empty()) {
        g_pending_frame = -1;
        return true;
    }
    write_ready();
    const bool capture = complete_surface &&
        frame >= static_cast<unsigned int>(g_trace_start_frame);
    if ((capture && !write_ppm(frame)) ||
        !write_owner_input(g_lockstep_dir / "inputs", frame, p1_pressed,
                           p2_pressed, system_pressed)) {
        request_stop("RTL capture publication failed");
        return false;
    }
    if (capture) {
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
            request_stop("RTL state publication failed");
            return false;
        }
        if (!g_trace_buffer.empty()) {
            std::ofstream trace(g_lockstep_dir / "rtl_trace.jsonl",
                                std::ios::binary | std::ios::app);
            trace.write(g_trace_buffer.data(),
                        std::streamsize(g_trace_buffer.size()));
            trace.flush();
            g_trace_buffer.clear();
            if (!trace) {
                request_stop("RTL trace publication failed");
                return false;
            }
        }
    }
    if (!atomic_file(g_lockstep_dir / "rtl_frame.txt",
                     std::to_string(frame) + "\n")) {
        request_stop("RTL frame token publication failed");
        return false;
    }
    g_pending_frame = -1;
    for (;;) {
        if (stop_requested()) return false;
        long long released = -1;
        if (read_release(released) && released >= static_cast<long long>(frame)) {
            if (std::filesystem::exists(g_lockstep_dir / "TRACE_STOP.txt"))
                g_trace_stopped = true;
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}
}  // namespace

extern "C" int ssv_visual_present(const svBitVecVal* pixels,
                                  unsigned int width,
                                  unsigned int height,
                                  unsigned int raster_frame) {
    if (width < 1 || width > kMaxWidth || height < 1 || height > kMaxHeight)
        return 1;
    g_width = int(width);
    g_height = int(height);
    for (int index = 0; index < g_width * g_height; ++index)
        g_pixels[index] = pixels[index] & 0x00ffffffu;
    g_pending_frame = raster_frame;
    return stop_requested() ? 1 : 0;
}

extern "C" void ssv_visual_set_geometry(unsigned int width,
                                         unsigned int height) {
    if (width >= 1 && width <= kMaxWidth) g_width = int(width);
    if (height >= 1 && height <= kMaxHeight) g_height = int(height);
}

extern "C" int ssv_visual_init() {
    init_paths();
    std::puts("SSV_HEADLESS_READY display_backend=none");
    std::fflush(stdout);
    return 0;
}

extern "C" int ssv_visual_poll() { return stop_requested() ? 1 : 0; }
extern "C" int ssv_visual_p1() { return 0; }
extern "C" int ssv_visual_system() { return 0; }

extern "C" void ssv_visual_trace_bus(
    unsigned long long frame, unsigned long long cycle, unsigned int pc,
    unsigned int write, unsigned int address, unsigned int data,
    unsigned int lanes, unsigned int device,
    const svLogicVecVal* v60_regs, unsigned int v60_psw) {
    init_paths();
    if (g_lockstep_dir.empty() || g_trace_stopped ||
        env_int("SSV_LOCKSTEP_TRACE", 1) == 0 ||
        frame < static_cast<unsigned long long>(g_trace_start_frame)) return;
    unsigned int normalized = 0;
    if (lanes & 1u) normalized |= data & 0x00ffu;
    if (lanes & 2u) normalized |= data & 0xff00u;
    std::ostringstream line;
    line << "{\"frame\":" << frame << ",\"cycle\":" << cycle
         << ",\"pc\":" << pc << ",\"cpu\":0,\"event\":\"bus\","
         << "\"rw\":\"" << (write ? 'w' : 'r') << "\",\"address\":"
         << address << ",\"data\":" << normalized << ",\"lanes\":"
         << (lanes & 3u) << ",\"device\":" << device;
    if (env_int("SSV_LOCKSTEP_TRACE_REGS", 0) != 0 && v60_regs) {
        for (int index = 0; index < 32; ++index)
            line << ",\"r" << index << "\":" << v60_regs[index].aval;
        line << ",\"psw\":" << v60_psw;
    }
    line << "}\n";
    g_trace_buffer.append(line.str());
}

extern "C" int ssv_visual_frame_commit(
    unsigned int frame, unsigned int p1_pressed, unsigned int p2_pressed,
    unsigned int system_pressed, unsigned int pc, unsigned int list512_crc,
    unsigned int spr8k_crc, unsigned int scroll63_crc,
    unsigned int pal512_crc, unsigned int st010_present,
    unsigned int st010_pc, unsigned int st010_a, unsigned int st010_b,
    unsigned int st010_dp, unsigned int st010_dr, unsigned int st010_k,
    unsigned int st010_l, unsigned int st010_m, unsigned int st010_n) {
    const bool committed = publish_and_wait(
        frame, p1_pressed, p2_pressed, system_pressed, pc, list512_crc,
        spr8k_crc, scroll63_crc, pal512_crc, st010_present, st010_pc,
        st010_a, st010_b, st010_dp, st010_dr, st010_k, st010_l, st010_m,
        st010_n);
    if (committed) {
        g_last_committed_frame.store(frame, std::memory_order_release);
        g_have_committed_frame.store(true, std::memory_order_release);
    }
    return committed ? 0 : 1;
}

extern "C" void ssv_visual_audio_sample(int sample_l, int sample_r,
                                         unsigned int) {
    ++g_audio_samples;
    if (sample_l || sample_r) ++g_audio_nonzero_samples;
}

extern "C" int ssv_visual_checkpoint_request_pending() { return 0; }
extern "C" int ssv_visual_checkpoint_consume_request(unsigned long long*) {
    return 0;
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
}
extern "C" int ssv_visual_checkpoint_after_restore() {
    g_pending_frame = -1;
    g_ready = false;
    g_trace_stopped = false;
    g_trace_buffer.clear();
    g_have_committed_frame.store(false, std::memory_order_release);
    std::puts("SSV_HEADLESS_CHECKPOINT_RESTORE_HOST_READY display_backend=none");
    std::fflush(stdout);
    return 0;
}

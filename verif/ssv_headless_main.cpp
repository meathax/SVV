#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "Vtb_ssv_frame_crc.h"
#include "verilated.h"
#ifdef SSV_HEADLESS_SAVABLE
#include "verilated_save.h"
#endif

namespace {
constexpr std::uint64_t kHalfPeriodPs = 5000;
#ifdef SSV_HEADLESS_SAVABLE
constexpr std::uint64_t kCheckpointMagic = 0x5353564845414431ULL;
constexpr std::uint64_t kCheckpointVersion = 1;
#endif

const char* plusarg(int argc, char** argv, const char* name) {
    const std::string prefix = std::string("+") + name + "=";
    for (int index = 1; index < argc; ++index) {
        const std::string argument(argv[index]);
        if (argument.rfind(prefix, 0) == 0) return argv[index] + prefix.size();
    }
    return nullptr;
}

struct InputPacket {
    unsigned p1 = 0;
    unsigned p2 = 0;
    unsigned system = 0;
};

std::map<unsigned, InputPacket> g_input_packets;
std::filesystem::path g_input_journal;
bool g_input_loaded = false;

bool json_uint(const std::string& text, const char* key, unsigned& value) {
    const std::string needle = std::string("\"") + key + "\"";
    const auto start = text.find(needle);
    if (start == std::string::npos) return false;
    const auto colon = text.find(':', start + needle.size());
    if (colon == std::string::npos) return false;
    const char* begin = text.c_str() + colon + 1;
    while (*begin == ' ' || *begin == '\t' || *begin == '\r' || *begin == '\n') ++begin;
    char* end = nullptr;
    errno = 0;
    const unsigned long long parsed = std::strtoull(begin, &end, 0);
    if (errno == ERANGE || end == begin || parsed > 0xffffu) return false;
    value = static_cast<unsigned>(parsed);
    return true;
}

bool parse_input_packet(const std::string& text, unsigned expected_frame,
                        InputPacket& packet) {
    unsigned frame = 0;
    if (!json_uint(text, "frame", frame) || frame != expected_frame) return false;
    if (!json_uint(text, "p1_pressed", packet.p1) ||
        !json_uint(text, "p2_pressed", packet.p2) ||
        !json_uint(text, "system_pressed", packet.system)) return false;
    return true;
}

void load_input_journal() {
    if (g_input_loaded) return;
    g_input_loaded = true;
    const char* environment = std::getenv("SSV_HEADLESS_INPUT_JOURNAL");
    if (!environment || !*environment) return;
    g_input_journal = std::filesystem::path(environment);
    std::error_code error;
    if (std::filesystem::is_directory(g_input_journal, error)) return;
    std::ifstream stream(g_input_journal);
    if (!stream) throw std::runtime_error("cannot open input journal: " + g_input_journal.string());
    std::string line;
    while (std::getline(stream, line)) {
        unsigned frame = 0;
        if (!json_uint(line, "frame", frame)) continue;
        InputPacket packet;
        if (!parse_input_packet(line, frame, packet))
            throw std::runtime_error("invalid input journal packet frame=" + std::to_string(frame));
        g_input_packets[frame] = packet;
    }
}

int ssv_headless_input_packet_impl(unsigned frame, unsigned* p1,
                                   unsigned* p2, unsigned* system) {
    try {
        load_input_journal();
        auto found = g_input_packets.find(frame);
        if (found == g_input_packets.end() && !g_input_journal.empty()) {
            std::error_code error;
            if (std::filesystem::is_directory(g_input_journal, error)) {
                const auto path = g_input_journal /
                    ("frame_" + [&] { char name[32]; std::snprintf(name, sizeof(name), "%06u", frame); return std::string(name); }() + ".json");
                std::ifstream stream(path);
                if (stream) {
                    std::ostringstream contents;
                    contents << stream.rdbuf();
                    InputPacket packet;
                    if (!parse_input_packet(contents.str(), frame, packet)) return 0;
                    found = g_input_packets.emplace(frame, packet).first;
                }
            }
        }
        if (found == g_input_packets.end()) return 0;
        *p1 = found->second.p1;
        *p2 = found->second.p2;
        *system = found->second.system;
        return 1;
    } catch (...) {
        return 0;
    }
}

std::uint64_t parse_unsigned(const char* value, std::uint64_t fallback) {
    if (!value || !*value) return fallback;
    errno = 0;
    char* end = nullptr;
    const auto parsed = std::strtoull(value, &end, 0);
    if (errno == ERANGE || !end || *end)
        throw std::runtime_error(std::string("invalid integer: ") + value);
    return static_cast<std::uint64_t>(parsed);
}

void ensure_parent(const std::filesystem::path& path) {
    if (path.has_parent_path()) std::filesystem::create_directories(path.parent_path());
}

std::string json_escape(const std::string& value) {
    std::string escaped;
    escaped.reserve(value.size() + 8);
    for (const char character : value) {
        if (character == '\\' || character == '"') escaped.push_back('\\');
        if (character == '\n') escaped += "\\n";
        else if (character == '\r') escaped += "\\r";
        else if (character == '\t') escaped += "\\t";
        else escaped.push_back(character);
    }
    return escaped;
}

void write_ppm_atomic(const std::filesystem::path& path, unsigned width,
                      unsigned height, const std::vector<std::uint8_t>& pixels) {
    if (pixels.size() != static_cast<std::size_t>(width) * height * 3)
        throw std::runtime_error("native frame has an incomplete pixel payload");
    ensure_parent(path);
    const auto temporary = std::filesystem::path(path.string() + ".tmp");
    {
        std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
        stream << "P6\n" << width << ' ' << height << "\n255\n";
        stream.write(reinterpret_cast<const char*>(pixels.data()),
                     static_cast<std::streamsize>(pixels.size()));
        if (!stream) throw std::runtime_error("failed to write native P6 frame");
    }
    std::error_code error;
    std::filesystem::remove(path, error);
    error.clear();
    std::filesystem::rename(temporary, path, error);
    if (error) throw std::runtime_error("failed to install native P6 frame: " + error.message());
}

void write_receipt(const std::filesystem::path& path, bool complete,
                   std::uint64_t cycles, std::uint64_t samples,
                   std::uint64_t pixels, const std::string& reason,
                   std::uint64_t native_frames = 0) {
    ensure_parent(path);
    std::ofstream stream(path, std::ios::trunc);
    const char* journal = std::getenv("SSV_HEADLESS_INPUT_JOURNAL");
    const char* scenario = std::getenv("SSV_HEADLESS_SCENARIO_FILE");
    const char* dsw1 = std::getenv("SSV_HEADLESS_DSW1");
    const char* dsw2 = std::getenv("SSV_HEADLESS_DSW2");
    stream << "{\n"
           << "  \"schema\": \"ssv-headless-receipt-v2\",\n"
           << "  \"headless\": true,\n"
           << "  \"display_backend\": \"none\",\n"
           << "  \"threads\": 1,\n"
           << "  \"video_format\": \"P6-RGB24-native-unrotated\",\n"
           << "  \"audio_format\": \"stereo-s16le-interleaved\",\n"
           << "  \"audio_sample_rate_hz\": null,\n"
           << "  \"audio_rate_contract\": \"source_tick_pending_deterministic_48k_resample\",\n"
           << "  \"complete\": " << (complete ? "true" : "false") << ",\n"
           << "  \"dropped\": 0,\n"
           << "  \"reason\": \"" << reason << "\",\n"
           << "  \"cycles\": " << cycles << ",\n"
           << "  \"audio_samples\": " << samples << ",\n"
           << "  \"captured_pixels\": " << pixels << ",\n"
           << "  \"native_frames\": " << native_frames << ",\n"
           << "  \"dips\": {\"DSW1\": " << (dsw1 ? dsw1 : "null")
           << ", \"DSW2\": " << (dsw2 ? dsw2 : "null") << "},\n"
           << "  \"input_journal\": "
           << (journal ? ("\"" + json_escape(journal) + "\"") : "null") << ",\n"
           << "  \"scenario_file\": "
           << (scenario ? ("\"" + json_escape(scenario) + "\"") : "null") << "\n"
           << "}\n";
    if (!stream) throw std::runtime_error("failed to write headless receipt");
}

#ifdef SSV_HEADLESS_SAVABLE
void save_checkpoint(Vtb_ssv_frame_crc& model, VerilatedContext& context,
                     const std::filesystem::path& path, std::uint64_t cycles) {
    ensure_parent(path);
    model.clk_sys = 0;
    model.checkpoint_prepare = 1;
    model.eval();
    const auto temporary = std::filesystem::path(path.string() + ".tmp");
    VerilatedSave save;
    save.open(temporary.string());
    if (!save.isOpen()) throw std::runtime_error("cannot open checkpoint output");
    save << kCheckpointMagic << kCheckpointVersion << cycles << &context << model;
    save.close();
    std::error_code error;
    std::filesystem::remove(path, error);
    error.clear();
    std::filesystem::rename(temporary, path, error);
    if (error) throw std::runtime_error("cannot install checkpoint: " + error.message());
    model.checkpoint_prepare = 0;
    model.eval();
    model.checkpoint_restore = 1;
    model.eval();
    model.checkpoint_restore = 0;
    model.eval();
    std::ofstream sidecar(path.string() + ".json", std::ios::trunc);
    const char* journal = std::getenv("SSV_HEADLESS_INPUT_JOURNAL");
    const char* scenario = std::getenv("SSV_HEADLESS_SCENARIO_FILE");
    sidecar << "{\n  \"schema\": \"ssv-headless-checkpoint-v2\",\n"
            << "  \"coordinate\": {\"kind\": \"cycle\", \"value\": " << cycles << "},\n"
            << "  \"headless\": true,\n  \"display_backend\": \"none\",\n"
            << "  \"acceptance_eligible\": false,\n"
            << "  \"requires_matching_cold_replay\": true,\n"
            << "  \"input_journal\": "
            << (journal ? ("\"" + json_escape(journal) + "\"") : "null") << ",\n"
            << "  \"scenario_file\": "
            << (scenario ? ("\"" + json_escape(scenario) + "\"") : "null") << "\n}\n";
    if (!sidecar) throw std::runtime_error("cannot write checkpoint sidecar");
}

std::uint64_t restore_checkpoint(Vtb_ssv_frame_crc& model,
                                 VerilatedContext& context,
                                 const std::filesystem::path& path) {
    VerilatedRestore restore;
    restore.open(path.string());
    if (!restore.isOpen()) throw std::runtime_error("cannot open checkpoint input");
    std::uint64_t magic = 0, version = 0, cycles = 0;
    restore >> magic >> version >> cycles >> &context >> model;
    restore.close();
    if (magic != kCheckpointMagic || version != kCheckpointVersion)
        throw std::runtime_error("incompatible headless checkpoint");
    model.clk_sys = 0;
    model.checkpoint_prepare = 0;
    model.checkpoint_restore = 1;
    model.eval();
    model.checkpoint_restore = 0;
    model.eval();
    return cycles;
}
#endif
}  // namespace

// DPI imports require an externally visible unmangled C symbol. Keep the
// parser state private above, but expose this one stable bridge to Verilator.
extern "C" int ssv_headless_input_packet(unsigned frame, unsigned* p1,
                                           unsigned* p2, unsigned* system) {
    return ssv_headless_input_packet_impl(frame, p1, p2, system);
}

double sc_time_stamp() { return 0.0; }

int main(int argc, char** argv) {
    try {
        auto context = std::make_unique<VerilatedContext>();
        context->commandArgs(argc, argv);
        context->threads(1);
        if (const char* journal = plusarg(argc, argv, "INPUT_JOURNAL")) {
#ifdef _WIN32
            _putenv_s("SSV_HEADLESS_INPUT_JOURNAL", journal);
#else
            setenv("SSV_HEADLESS_INPUT_JOURNAL", journal, 1);
#endif
        }
        if (const char* scenario = plusarg(argc, argv, "SCENARIO_FILE")) {
#ifdef _WIN32
            _putenv_s("SSV_HEADLESS_SCENARIO_FILE", scenario);
#else
            setenv("SSV_HEADLESS_SCENARIO_FILE", scenario, 1);
#endif
        }
        auto model = std::make_unique<Vtb_ssv_frame_crc>(context.get());
        model->clk_sys = 0;
        model->checkpoint_prepare = 0;
        model->checkpoint_restore = 0;
        std::uint64_t cycles = 0;
#ifdef SSV_HEADLESS_SAVABLE
        if (const char* restore = plusarg(argc, argv, "HEADLESS_RESTORE"))
            cycles = restore_checkpoint(*model, *context, restore);
        else
            model->eval();
#else
        if (plusarg(argc, argv, "HEADLESS_RESTORE"))
            throw std::runtime_error("checkpoint restore requires the acceleration profile");
        model->eval();
#endif

        const unsigned width = parse_unsigned(plusarg(argc, argv, "HEADLESS_WIDTH"), 336);
        const unsigned height = parse_unsigned(plusarg(argc, argv, "HEADLESS_HEIGHT"), 240);
        const std::filesystem::path ppm_path = plusarg(argc, argv, "HEADLESS_PPM")
            ? plusarg(argc, argv, "HEADLESS_PPM") : "sim_output/diff/rtl-native.ppm";
        const std::filesystem::path pcm_path = plusarg(argc, argv, "HEADLESS_PCM")
            ? plusarg(argc, argv, "HEADLESS_PCM") : "sim_output/diff/rtl-audio-s16le.pcm";
        const std::filesystem::path receipt_path = plusarg(argc, argv, "HEADLESS_RECEIPT")
            ? plusarg(argc, argv, "HEADLESS_RECEIPT") : "sim_output/diff/rtl-receipt.json";
        ensure_parent(pcm_path);
        std::ofstream pcm(pcm_path, std::ios::binary | std::ios::trunc);
        if (!pcm) throw std::runtime_error("cannot open raw PCM output");

        std::vector<std::uint8_t> frame;
        frame.reserve(static_cast<std::size_t>(width) * height * 3);
        std::vector<std::uint8_t> last_complete_frame;
        std::uint64_t samples = 0;
#ifdef SSV_HEADLESS_SAVABLE
        const std::filesystem::path checkpoint_path = plusarg(argc, argv, "HEADLESS_CHECKPOINT")
            ? plusarg(argc, argv, "HEADLESS_CHECKPOINT") : "sim_output/checkpoints/ssv-headless.vltsv";
        const std::filesystem::path checkpoint_control = plusarg(argc, argv, "HEADLESS_CHECKPOINT_CONTROL")
            ? plusarg(argc, argv, "HEADLESS_CHECKPOINT_CONTROL") : std::filesystem::path();
        const std::uint64_t save_cycle = parse_unsigned(
            plusarg(argc, argv, "HEADLESS_SAVE_CYCLE"), 0);
        bool checkpoint_saved = false;
#endif

        // The behavioural SDRAM model has a real 2.5 ns internal clock while
        // the host owns the 5 ns clk_sys edge. Jumping directly from one
        // external edge to the next with timeInc() skips that pending timing
        // slot and Verilator correctly aborts. Drain every scheduled internal
        // event before advancing to the next host edge.
        auto eval_until = [&](std::uint64_t target_ps) {
            while (model->eventsPending() &&
                   model->nextTimeSlot() <= target_ps) {
                context->time(model->nextTimeSlot());
                model->eval();
            }
            context->time(target_ps);
            model->eval();
        };

        while (!context->gotFinish() && !model->run_done) {
            model->clk_sys = 1;
            model->eval();
            eval_until(context->time() + kHalfPeriodPs);

            if (model->headless_pixel_valid &&
                frame.size() < static_cast<std::size_t>(width) * height * 3) {
                const std::uint32_t rgb = model->headless_rgb;
                frame.push_back(static_cast<std::uint8_t>(rgb >> 16));
                frame.push_back(static_cast<std::uint8_t>(rgb >> 8));
                frame.push_back(static_cast<std::uint8_t>(rgb));
            }
            if (model->headless_audio_valid) {
                const std::int16_t left = model->headless_audio_l;
                const std::int16_t right = model->headless_audio_r;
                pcm.write(reinterpret_cast<const char*>(&left), sizeof(left));
                pcm.write(reinterpret_cast<const char*>(&right), sizeof(right));
                ++samples;
            }
            if (model->headless_frame_tick) {
                if (frame.size() == static_cast<std::size_t>(width) * height * 3)
                    last_complete_frame = frame;
                frame.clear();
            }

            model->clk_sys = 0;
            model->eval();
            eval_until(context->time() + kHalfPeriodPs);
            ++cycles;
#ifdef SSV_HEADLESS_SAVABLE
            const bool control_requested = !checkpoint_control.empty() &&
                std::filesystem::is_regular_file(checkpoint_control);
            if (!checkpoint_saved && ((save_cycle != 0 && cycles >= save_cycle) ||
                                      control_requested)) {
                save_checkpoint(*model, *context, checkpoint_path, cycles);
                checkpoint_saved = true;
                if (control_requested) {
                    std::ofstream acknowledgement(checkpoint_control.string() + ".ack",
                                                  std::ios::trunc);
                    acknowledgement << "saved " << checkpoint_path.string()
                                    << " cycle " << cycles << "\n";
                }
            }
#endif
        }

        // The legacy bench publishes run_done and calls $finish in the same
        // final evaluation.  Verilator therefore reports gotFinish() at the
        // same boundary that exposes a valid stop barrier.  run_done is the
        // authoritative project-owned completion signal; rejecting it when
        // gotFinish() is already set mislabels a full PASS as an abort.
        const bool completed = model->run_done;
        model->final();
        pcm.close();
        if (!completed) {
            write_receipt(receipt_path, false, cycles, samples, 0, "aborted");
            throw std::runtime_error("run ended before the declared stop barrier");
        }
        if (last_complete_frame.empty()) {
            write_receipt(receipt_path, false, cycles, samples, 0, "incomplete_frame");
            throw std::runtime_error("run ended without a complete native frame");
        }
        write_ppm_atomic(ppm_path, width, height, last_complete_frame);
        write_receipt(receipt_path, true, cycles, samples,
                      last_complete_frame.size() / 3, "stop_barrier",
                      model->checkpoint_post_ve_frame);
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "SSV_HEADLESS_ERROR %s\n", error.what());
        return 2;
    }
}

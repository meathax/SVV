#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <string>
#include <system_error>

#ifdef _WIN32
#include <fcntl.h>
#endif

#include "Vtb_ssv_frame_crc.h"
#include "verilated.h"
#include "verilated_save.h"

extern "C" int ssv_visual_checkpoint_request_pending();
extern "C" int ssv_visual_checkpoint_consume_request(
    unsigned long long* committed_frame);
extern "C" int ssv_visual_checkpoint_last_committed_frame(
    unsigned long long* committed_frame);
extern "C" void ssv_visual_checkpoint_notify_saved(
    const char* path, const char* coordinate_name,
    unsigned long long coordinate, int success);
extern "C" int ssv_visual_checkpoint_after_restore();

// This host is exclusively for the SSV_VISUAL_EXTERNAL_CLOCK/--no-timing
// profile. The existing timing host remains ssv_visual_sdl.cpp compiled with
// SSV_VISUAL_NO_SAVE and continues to use Verilator's generated main.
//
// Exact top-level contract (kept explicit so an interface drift fails at
// compile time instead of silently producing an unsafe archive):
//   input  clk_sys
//   input  checkpoint_prepare
//   input  checkpoint_restore
//   output run_done

namespace {
constexpr unsigned long long kArchiveMagic = 0x535356564c545356ULL;
constexpr unsigned long long kArchiveVersion = 2;
constexpr unsigned long long kCoordinateFrame = 0;
constexpr unsigned long long kCoordinateNativeFrame = 1;
constexpr unsigned long long kHalfPeriodTicks = 5000;  // 5 ns at 1 ps.

const char* value_plusarg(int argc, char** argv, const char* name) {
    const std::string prefix = std::string("+") + name + "=";
    for (int index = 1; index < argc; ++index) {
        const std::string argument(argv[index]);
        if (argument.rfind(prefix, 0) == 0)
            return argv[index] + prefix.size();
    }
    return nullptr;
}

bool enabled_plusarg(int argc, char** argv, const char* name) {
    const char* value = value_plusarg(argc, argv, name);
    return value && std::string(value) == "1";
}

bool parse_unsigned(const char* value, unsigned long long& result) {
    if (!value || !*value) return false;
    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(value, &end, 0);
    if (!end || *end) return false;
    result = parsed;
    return true;
}

bool nonempty_regular_file(const std::filesystem::path& path) {
    std::error_code error;
    return std::filesystem::is_regular_file(path, error) && !error &&
           std::filesystem::file_size(path, error) > 0 && !error;
}

bool install_checkpoint(const std::filesystem::path& temporary,
                        const std::filesystem::path& target) {
    const std::filesystem::path backup(target.string() + ".bak");
    std::error_code error;
    bool moved_old = false;

    if (std::filesystem::exists(target, error) && !error) {
        error.clear();
        std::filesystem::remove(backup, error);
        error.clear();
        std::filesystem::rename(target, backup, error);
        if (error) {
            std::fprintf(stderr,
                         "SSV_CHECKPOINT_ERROR backup target=%s backup=%s error=%s\n",
                         target.string().c_str(), backup.string().c_str(),
                         error.message().c_str());
            return false;
        }
        moved_old = true;
    }

    error.clear();
    std::filesystem::rename(temporary, target, error);
    if (!error) return true;

    std::fprintf(stderr,
                 "SSV_CHECKPOINT_ERROR install temp=%s target=%s error=%s\n",
                 temporary.string().c_str(), target.string().c_str(),
                 error.message().c_str());
    if (moved_old) {
        std::error_code recovery_error;
        std::filesystem::rename(backup, target, recovery_error);
        if (recovery_error)
            std::fprintf(stderr,
                         "SSV_CHECKPOINT_ERROR recovery backup=%s target=%s error=%s\n",
                         backup.string().c_str(), target.string().c_str(),
                         recovery_error.message().c_str());
    }
    return false;
}

bool save_checkpoint(Vtb_ssv_frame_crc& model, VerilatedContext& context,
                     const std::filesystem::path& target,
                     unsigned long long coordinate_kind,
                     unsigned long long coordinate) {
    std::error_code error;
    if (!target.parent_path().empty()) {
        std::filesystem::create_directories(target.parent_path(), error);
        if (error) {
            std::fprintf(stderr,
                         "SSV_CHECKPOINT_ERROR mkdir path=%s error=%s\n",
                         target.parent_path().string().c_str(),
                         error.message().c_str());
            return false;
        }
    }

    const std::filesystem::path temporary(target.string() + ".tmp");
    error.clear();
    std::filesystem::remove(temporary, error);

    // The frame-commit DPI call has returned before main reaches here. Keep
    // clk_sys low and let SV close/flush every process-local file handle before
    // taking the full-state snapshot.
    model.clk_sys = 0;
    model.checkpoint_prepare = 1;
    model.eval();

    bool serialized = false;
    {
        VerilatedSave save;
        save.open(temporary.string());
        if (save.isOpen()) {
            save << kArchiveMagic << kArchiveVersion << coordinate_kind
                 << coordinate
                 << &context << model;
            save.close();
            serialized = nonempty_regular_file(temporary);
        }
    }

    model.checkpoint_prepare = 0;
    model.eval();

    // Resume process-local evidence streams in the current process. The saved
    // archive intentionally retains their prepared/closed state; a fresh
    // restore performs the same pulse in restore_checkpoint().
    model.checkpoint_restore = 1;
    model.eval();
    model.checkpoint_restore = 0;
    model.eval();

    if (!serialized) {
        std::fprintf(stderr,
                     "SSV_CHECKPOINT_ERROR serialize temp=%s\n",
                     temporary.string().c_str());
        error.clear();
        std::filesystem::remove(temporary, error);
        return false;
    }
    return install_checkpoint(temporary, target);
}

bool restore_checkpoint(Vtb_ssv_frame_crc& model, VerilatedContext& context,
                        const std::filesystem::path& source,
                        unsigned long long& coordinate_kind,
                        unsigned long long& coordinate) {
    if (!nonempty_regular_file(source)) {
        std::fprintf(stderr,
                     "SSV_RESTORE_ERROR missing_or_empty path=%s\n",
                     source.string().c_str());
        return false;
    }

    unsigned long long magic = 0;
    unsigned long long version = 0;
    VerilatedRestore restore;
    restore.open(source.string());
    if (!restore.isOpen()) {
        std::fprintf(stderr, "SSV_RESTORE_ERROR open path=%s\n",
                     source.string().c_str());
        return false;
    }
    restore >> magic >> version;
    if (version == 1) {
        coordinate_kind = kCoordinateFrame;
        restore >> coordinate >> &context >> model;
    } else if (version == kArchiveVersion) {
        restore >> coordinate_kind >> coordinate >> &context >> model;
    }
    restore.close();
    if (magic != kArchiveMagic ||
        (version != 1 && version != kArchiveVersion) ||
        coordinate_kind > kCoordinateNativeFrame) {
        std::fprintf(stderr,
                     "SSV_RESTORE_ERROR incompatible path=%s magic=%016llx version=%llu\n",
                     source.string().c_str(), magic, version);
        return false;
    }

    // Inputs are serialized with the model, so override every host-owned
    // control explicitly. SV reopens append-mode evidence streams and ROM/media
    // handles while checkpoint_restore is asserted at the quiescent low level.
    model.clk_sys = 0;
    model.checkpoint_prepare = 0;
    model.checkpoint_restore = 1;
    model.eval();
    model.checkpoint_restore = 0;
    model.eval();

    if (ssv_visual_checkpoint_after_restore() != 0) {
        std::fprintf(stderr,
                     "SSV_RESTORE_ERROR process_local_host_init path=%s\n",
                     source.string().c_str());
        return false;
    }
    std::printf("SSV_RESTORE_OK path=%s %s=%llu fresh_process_media=1\n",
                source.string().c_str(),
                coordinate_kind == kCoordinateNativeFrame
                    ? "native_frame" : "frame",
                coordinate);
    std::fflush(stdout);
    return true;
}
}  // namespace

double sc_time_stamp() { return 0.0; }

int main(int argc, char** argv) {
#ifdef _WIN32
    // VerilatedSave uses ::open without _O_BINARY. MinGW otherwise inherits
    // text mode and can corrupt the archive at CR/LF or Ctrl-Z bytes.
    _set_fmode(_O_BINARY);
#endif

    auto context = std::make_unique<VerilatedContext>();
    context->commandArgs(argc, argv);
    auto model = std::make_unique<Vtb_ssv_frame_crc>(context.get());
    model->clk_sys = 0;
    model->checkpoint_prepare = 0;
    model->checkpoint_restore = 0;

    const char* checkpoint_value = value_plusarg(argc, argv, "CHECKPOINT");
    const std::filesystem::path checkpoint_path =
        (checkpoint_value && *checkpoint_value)
            ? std::filesystem::path(checkpoint_value)
            : std::filesystem::path("ssv_checkpoint.vltsv");

    bool restored = false;
    const char* restore_value = value_plusarg(argc, argv, "RESTORE");
    if (restore_value && *restore_value) {
        unsigned long long restored_kind = 0;
        unsigned long long restored_coordinate = 0;
        if (!restore_checkpoint(*model, *context,
                                std::filesystem::path(restore_value),
                                restored_kind, restored_coordinate))
            return 2;
        restored = true;
    } else {
        // Execute initial blocks at a stable low clock. Thereafter every clock
        // receives high and low evaluations, including a real falling-edge
        // eval; the model never relies on a timing scheduler.
        model->eval();
    }

    unsigned long long save_frame = 0;
    const char* save_frame_value = value_plusarg(argc, argv, "SAVE_FRAME");
    const bool have_save_frame =
        save_frame_value && parse_unsigned(save_frame_value, save_frame);
    if (save_frame_value && !have_save_frame) {
        std::fprintf(stderr, "SSV_CHECKPOINT_ERROR invalid +SAVE_FRAME=%s\n",
                     save_frame_value);
        model->final();
        return 3;
    }
    unsigned long long save_native_frame = 0;
    const char* save_native_frame_value =
        value_plusarg(argc, argv, "SAVE_NATIVE_FRAME");
    const bool have_save_native_frame =
        save_native_frame_value &&
        parse_unsigned(save_native_frame_value, save_native_frame);
    if (save_native_frame_value && !have_save_native_frame) {
        std::fprintf(stderr,
                     "SSV_CHECKPOINT_ERROR invalid +SAVE_NATIVE_FRAME=%s\n",
                     save_native_frame_value);
        model->final();
        return 3;
    }
    if (have_save_frame && have_save_native_frame) {
        std::fprintf(stderr,
                     "SSV_CHECKPOINT_ERROR choose one automatic save coordinate\n");
        model->final();
        return 3;
    }
    const bool keep_running_after_save =
        enabled_plusarg(argc, argv, "KEEP_RUNNING_AFTER_SAVE");

    bool automatic_save_attempted = false;
    int exit_code = 0;
    while (!context->gotFinish() && !model->run_done) {
        context->timeInc(kHalfPeriodTicks);
        model->clk_sys = 1;
        model->eval();

        context->timeInc(kHalfPeriodTicks);
        model->clk_sys = 0;
        model->eval();  // Mandatory falling-edge evaluation.

        unsigned long long committed_frame = 0;
        const bool interactive_request =
            ssv_visual_checkpoint_consume_request(&committed_frame) != 0;
        bool automatic_request = false;
        unsigned long long coordinate_kind = kCoordinateFrame;
        if (have_save_frame && !automatic_save_attempted) {
            unsigned long long last_frame = 0;
            if (ssv_visual_checkpoint_last_committed_frame(&last_frame) != 0 &&
                last_frame >= save_frame) {
                committed_frame = last_frame;
                automatic_request = true;
                automatic_save_attempted = true;
            }
        }
        if (have_save_native_frame && !automatic_save_attempted &&
            model->checkpoint_native_frame >= save_native_frame) {
            committed_frame = model->checkpoint_native_frame;
            coordinate_kind = kCoordinateNativeFrame;
            automatic_request = true;
            automatic_save_attempted = true;
        }

        if (interactive_request || automatic_request) {
            const bool saved = save_checkpoint(
                *model, *context, checkpoint_path, coordinate_kind,
                committed_frame);
            ssv_visual_checkpoint_notify_saved(
                checkpoint_path.string().c_str(),
                coordinate_kind == kCoordinateNativeFrame
                    ? "native_frame" : "frame",
                committed_frame,
                saved ? 1 : 0);
            if (!saved) {
                exit_code = 4;
                break;
            }
            // +SAVE_FRAME is the bounded-chunk automation path: save one safe
            // native-frame checkpoint and release the simulator slot. F5 and
            // Ctrl+S remain interactive and continue running after the save.
            if (automatic_request && !keep_running_after_save)
                break;
        }
    }

    // Suppress an otherwise-unused warning while retaining a clear diagnostic
    // distinction in debuggers between fresh and restored startup.
    (void)restored;
    model->final();
    return exit_code;
}

#include "kiro_sd.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <random>
#include <string>

#include "stable-diffusion.h"

#define STB_IMAGE_WRITE_STATIC
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#if defined(__ANDROID__)
#include <android/log.h>
#define KLOG(...) __android_log_print(ANDROID_LOG_INFO, "kiro_sd", __VA_ARGS__)
#else
#define KLOG(...) ((void)0)
#endif

struct kiro_sd {
    sd_ctx_t* ctx = nullptr;
    std::atomic<bool> cancelled{false};
};

namespace {

// stable-diffusion.cpp keeps one global progress callback; generations are serialised.
std::mutex g_generate_mutex;
kiro_sd_progress_fn g_progress = nullptr;
void* g_progress_user = nullptr;

void on_progress(int step, int steps, float /*time*/, void* /*data*/) {
    if (g_progress) g_progress(step, steps, g_progress_user);
}

void on_log(enum sd_log_level_t level, const char* text, void* /*data*/) {
    if (level >= SD_LOG_WARN && text) KLOG("%s", text);
}

bool non_empty(const char* s) { return s && s[0] != '\0'; }

}  // namespace

extern "C" {

kiro_sd* kiro_sd_load(const char* model_path, const char* taesd_path, int n_threads) {
    if (!non_empty(model_path)) return nullptr;
    sd_set_log_callback(on_log, nullptr);

    sd_ctx_params_t p;
    sd_ctx_params_init(&p);
    p.model_path = model_path;
    p.taesd_path = non_empty(taesd_path) ? taesd_path : "";
    p.n_threads = n_threads > 0 ? n_threads : sd_get_num_physical_cores();
    p.enable_mmap = true;       // weights stay file-backed: lower peak RSS on phones
    p.vae_conv_direct = false;
    p.diffusion_flash_attn = false;

    sd_ctx_t* ctx = new_sd_ctx(&p);
    if (!ctx) return nullptr;
    auto* k = new kiro_sd();
    k->ctx = ctx;
    return k;
}

int kiro_sd_txt2img(kiro_sd* k,
                    const char* prompt,
                    const char* negative_prompt,
                    int width,
                    int height,
                    int steps,
                    float cfg,
                    int64_t seed,
                    const char* out_png_path,
                    kiro_sd_progress_fn progress,
                    void* user,
                    int64_t* seed_out) {
    if (!k || !k->ctx || !non_empty(prompt) || !non_empty(out_png_path)) return KIRO_SD_ERR_ARGS;
    if (width < 64 || height < 64 || width > 2048 || height > 2048 || width % 64 || height % 64) return KIRO_SD_ERR_ARGS;

    std::lock_guard<std::mutex> lock(g_generate_mutex);
    k->cancelled.store(false);
    sd_cancel_generation(k->ctx, SD_CANCEL_RESET);

    if (seed < 0) {
        std::random_device rd;
        seed = static_cast<int64_t>(((uint64_t)rd() << 16) ^ (uint64_t)rd()) & 0x7fffffff;
    }
    if (seed_out) *seed_out = seed;

    sd_img_gen_params_t g;
    sd_img_gen_params_init(&g);
    g.prompt = prompt;
    g.negative_prompt = negative_prompt ? negative_prompt : "";
    g.width = width;
    g.height = height;
    g.seed = seed;
    g.batch_count = 1;
    if (steps > 0) g.sample_params.sample_steps = steps;
    if (cfg > 0.f) g.sample_params.guidance.txt_cfg = cfg;

    g_progress = progress;
    g_progress_user = user;
    sd_set_progress_callback(on_progress, nullptr);

    sd_image_generation_result_t* result = nullptr;
    const bool ok = generate_image(k->ctx, &g, &result);

    sd_set_progress_callback(nullptr, nullptr);
    g_progress = nullptr;
    g_progress_user = nullptr;

    if (k->cancelled.load()) {
        if (result) free_sd_image_generation_result(result);
        return KIRO_SD_ERR_CANCELLED;
    }
    if (!ok || !result || result->count < 1 || !result->items[0].image.data) {
        if (result) free_sd_image_generation_result(result);
        return KIRO_SD_ERR_GENERATE;
    }
    const sd_image_t& img = result->items[0].image;
    const int w = (int)img.width, h = (int)img.height, c = (int)img.channel;
    const int written = stbi_write_png(out_png_path, w, h, c, img.data, w * c);
    free_sd_image_generation_result(result);
    return written ? KIRO_SD_OK : KIRO_SD_ERR_WRITE;
}

void kiro_sd_cancel(kiro_sd* k) {
    if (!k || !k->ctx) return;
    k->cancelled.store(true);
    sd_cancel_generation(k->ctx, SD_CANCEL_ALL);
}

const char* kiro_sd_model_name(kiro_sd* k) {
    if (!k || !k->ctx) return "";
    return sd_get_model_version_name(k->ctx);
}

const char* kiro_sd_system_info(void) {
    static std::string info;
    static std::once_flag once;
    std::call_once(once, [] {
        info = std::string("stable-diffusion.cpp ") + sd_version() + " (" + sd_commit() + ")\n" + sd_get_system_info();
    });
    return info.c_str();
}

void kiro_sd_free(kiro_sd* k) {
    if (!k) return;
    if (k->ctx) free_sd_ctx(k->ctx);
    delete k;
}

}  // extern "C"

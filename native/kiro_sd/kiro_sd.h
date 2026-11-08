/*
 * Kiro image engine: a small, stable C API over stable-diffusion.cpp.
 *
 * Shared by every platform: Android calls it through JNI (kiro_sd_jni.cpp, inside the
 * ":ai" process); Windows/Linux desktop builds call the same functions through dart:ffi.
 * All functions are thread-compatible: one context is used by one thread at a time, except
 * kiro_sd_cancel(), which may be called from any thread.
 */
#ifndef KIRO_SD_H
#define KIRO_SD_H

#include <stdint.h>

#if defined(_WIN32)
#define KIRO_SD_API __declspec(dllexport)
#else
#define KIRO_SD_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kiro_sd kiro_sd;

/* Status codes returned by kiro_sd_txt2img. */
#define KIRO_SD_OK 0
#define KIRO_SD_ERR_ARGS -1
#define KIRO_SD_ERR_GENERATE -2
#define KIRO_SD_ERR_CANCELLED -3
#define KIRO_SD_ERR_WRITE -4

/* Called after every denoising step (and once with step == steps for decoding). */
typedef void (*kiro_sd_progress_fn)(int step, int steps, void* user);

/*
 * Loads a Stable Diffusion checkpoint (.gguf / .safetensors). taesd_path may be NULL or "";
 * when set, the tiny TAESD decoder replaces the full VAE (much faster, less memory).
 * Returns NULL on failure.
 */
KIRO_SD_API kiro_sd* kiro_sd_load(const char* model_path, const char* taesd_path, int n_threads);

/*
 * Generates one image and writes it as PNG to out_png_path.
 * steps <= 0 and cfg <= 0 select the model's defaults; seed < 0 picks a random seed.
 * The seed actually used is stored in *seed_out when it is not NULL.
 */
KIRO_SD_API int kiro_sd_txt2img(kiro_sd* ctx,
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
                                int64_t* seed_out);

/* Requests the running generation to stop as soon as possible. */
KIRO_SD_API void kiro_sd_cancel(kiro_sd* ctx);

/* Human-readable model version ("SD 2.x", ...). Owned by the library. */
KIRO_SD_API const char* kiro_sd_model_name(kiro_sd* ctx);

/* stable-diffusion.cpp build info (version + ggml system info). Owned by the library. */
KIRO_SD_API const char* kiro_sd_system_info(void);

KIRO_SD_API void kiro_sd_free(kiro_sd* ctx);

#ifdef __cplusplus
}
#endif

#endif /* KIRO_SD_H */

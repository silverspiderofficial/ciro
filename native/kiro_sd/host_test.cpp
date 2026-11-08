// Host check of the kiro_sd C API: kiro_sd_host_test <model> <taesd|-> <out.png> [steps] [threads]
#include <cstdio>
#include <cstdlib>
#include <chrono>

#include "kiro_sd.h"

static void progress(int step, int steps, void*) { std::printf("step %d/%d\n", step, steps); std::fflush(stdout); }

int main(int argc, char** argv) {
    if (argc < 4) { std::fprintf(stderr, "usage: %s model taesd|- out.png [steps] [threads]\n", argv[0]); return 2; }
    const char* taesd = (argv[2][0] == '-') ? "" : argv[2];
    const int steps = argc > 4 ? std::atoi(argv[4]) : 2;
    const int threads = argc > 5 ? std::atoi(argv[5]) : 2;
    std::printf("%s\n", kiro_sd_system_info());
    auto t0 = std::chrono::steady_clock::now();
    kiro_sd* ctx = kiro_sd_load(argv[1], taesd, threads);
    if (!ctx) { std::fprintf(stderr, "load failed\n"); return 1; }
    auto t1 = std::chrono::steady_clock::now();
    std::printf("model: %s, load %.1fs\n", kiro_sd_model_name(ctx), std::chrono::duration<double>(t1 - t0).count());
    int64_t seed = 0;
    int rc = kiro_sd_txt2img(ctx, "a cozy coffee cup on a wooden table, morning light, photo", "blurry, text", 512, 512,
                             steps, 1.0f, 42, argv[3], progress, nullptr, &seed);
    auto t2 = std::chrono::steady_clock::now();
    std::printf("rc=%d seed=%lld gen %.1fs\n", rc, (long long)seed, std::chrono::duration<double>(t2 - t1).count());
    kiro_sd_free(ctx);
    return rc == 0 ? 0 : 1;
}

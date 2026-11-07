// Kiro on-device LLM engine: a thin, thread-safe wrapper over llama.cpp.
// Pure C++ (no JNI) so it can be unit-tested on a host machine.
#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace kiro {

struct ChatMessage {
    std::string role;     // "system" | "user" | "assistant"
    std::string content;
};

struct GenParams {
    int32_t max_tokens = 512;
    float temperature = 0.7f;
    float top_p = 0.9f;
    int32_t top_k = 40;
    float min_p = 0.05f;
    float repeat_penalty = 1.1f;
    int32_t repeat_last_n = 64;
    uint32_t seed = 0xFFFFFFFFu;  // LLAMA_DEFAULT_SEED (random)
};

struct GenStats {
    int32_t prompt_tokens = 0;
    int32_t reused_tokens = 0;
    int32_t generated_tokens = 0;
    double prefill_ms = 0.0;
    double generate_ms = 0.0;
};

// Status codes returned by generate(). Kept in sync with LlamaNative.kt.
enum GenStatus : int32_t {
    GEN_DONE = 0,            // end-of-generation token reached
    GEN_MAX_TOKENS = 1,      // max_tokens reached
    GEN_CANCELLED = 2,       // cancel() was called or callback returned false
    GEN_CONTEXT_FULL = 3,    // context window filled during generation
    GEN_ERR_NOT_LOADED = -1,
    GEN_ERR_TEMPLATE = -2,
    GEN_ERR_TOKENIZE = -3,
    GEN_ERR_PROMPT_TOO_LONG = -4,
    GEN_ERR_DECODE = -5,
    GEN_ERR_BUSY = -6,
};

// Load result codes. Kept in sync with LlamaNative.kt.
enum LoadStatus : int32_t {
    LOAD_OK = 0,
    LOAD_ERR_MODEL = 1,
    LOAD_ERR_CONTEXT = 2,
    LOAD_ERR_NO_BACKEND = 3,
};

// Receives complete UTF-8 chunks. Return false to stop generation.
using TokenSink = std::function<bool(const std::string &utf8)>;

// Initialise llama.cpp backends. backend_dir may be empty (statically linked CPU backend).
// Returns the number of compute devices available.
int32_t init_backends(const std::string &backend_dir);

int32_t load_model(const std::string &path, int32_t n_ctx, int32_t n_threads);
void unload_model();
bool is_loaded();

// Applies the model's own chat template (GGUF metadata "tokenizer.chat_template"),
// falling back to ChatML when the model has none or it is unsupported.
int32_t generate(const std::vector<ChatMessage> &messages, const GenParams &params,
                 const TokenSink &sink, GenStats *stats);

// Thread-safe: may be called from any thread while generate() runs.
void cancel();

// Human readable model description, e.g. "qwen2 1.5B Q4_K - Medium".
std::string model_description();
int32_t context_size();
std::string chat_template_name();

// Exposed for tests: length of the longest prefix of s that is complete UTF-8.
size_t complete_utf8_prefix(const std::string &s);

}  // namespace kiro

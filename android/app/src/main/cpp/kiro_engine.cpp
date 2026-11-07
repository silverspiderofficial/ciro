#include "kiro_engine.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>

#include "ggml-backend.h"
#include "llama.h"

#if defined(__ANDROID__)
#include <android/log.h>
#define KIRO_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "kiro-llm", __VA_ARGS__)
#else
#include <cstdio>
#define KIRO_LOGE(...) (std::fprintf(stderr, __VA_ARGS__), std::fputc('\n', stderr))
#endif

namespace kiro {
namespace {

struct EngineState {
    llama_model *model = nullptr;
    llama_context *ctx = nullptr;
    const llama_vocab *vocab = nullptr;
    std::vector<llama_token> cached;  // tokens currently held in the KV cache (seq 0)
    std::string tmpl;                 // chat template source from GGUF, empty = ChatML
    std::string tmpl_name = "chatml";
    int32_t n_ctx = 0;
    int32_t n_batch = 512;
};

EngineState g_state;
std::mutex g_mutex;               // guards g_state; generate/load/unload are serialised
std::atomic<bool> g_cancel{false};
std::atomic<bool> g_backends_ready{false};

bool abort_callback(void * /*data*/) { return g_cancel.load(std::memory_order_relaxed); }

void log_callback(ggml_log_level level, const char *text, void * /*user*/) {
    // Only surface errors; release builds should not leak prompts or paths into logcat.
    if (level == GGML_LOG_LEVEL_ERROR && text != nullptr) {
        KIRO_LOGE("%s", text);
    }
}

void free_locked() {
    if (g_state.ctx != nullptr) {
        llama_free(g_state.ctx);
        g_state.ctx = nullptr;
    }
    if (g_state.model != nullptr) {
        llama_model_free(g_state.model);
        g_state.model = nullptr;
    }
    g_state.vocab = nullptr;
    g_state.cached.clear();
    g_state.tmpl.clear();
    g_state.tmpl_name = "chatml";
    g_state.n_ctx = 0;
}

double ms_since(std::chrono::steady_clock::time_point t0) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

// Formats the conversation with the given template. Returns false if the template is unsupported.
bool apply_template(const char *tmpl, const std::vector<llama_chat_message> &msgs, std::string &out) {
    size_t total = 0;
    for (const auto &m : msgs) total += std::strlen(m.content) + 64;
    std::vector<char> buf(std::max<size_t>(total * 2, 1024));
    int32_t n = llama_chat_apply_template(tmpl, msgs.data(), msgs.size(), true, buf.data(),
                                          static_cast<int32_t>(buf.size()));
    if (n < 0) return false;
    if (static_cast<size_t>(n) > buf.size()) {
        buf.resize(static_cast<size_t>(n) + 1);
        n = llama_chat_apply_template(tmpl, msgs.data(), msgs.size(), true, buf.data(),
                                      static_cast<int32_t>(buf.size()));
        if (n < 0) return false;
    }
    out.assign(buf.data(), static_cast<size_t>(n));
    return true;
}

bool tokenize(const std::string &text, std::vector<llama_token> &out) {
    const int32_t len = static_cast<int32_t>(text.size());
    int32_t n = -llama_tokenize(g_state.vocab, text.data(), len, nullptr, 0, true, true);
    if (n <= 0) return false;
    out.resize(static_cast<size_t>(n));
    const int32_t got = llama_tokenize(g_state.vocab, text.data(), len, out.data(), n, true, true);
    if (got < 0) return false;
    out.resize(static_cast<size_t>(got));
    return true;
}

std::string token_piece(llama_token tok) {
    char small[128];
    int32_t n = llama_token_to_piece(g_state.vocab, tok, small, sizeof(small), 0, false);
    if (n >= 0) return std::string(small, static_cast<size_t>(n));
    std::string big(static_cast<size_t>(-n), '\0');
    n = llama_token_to_piece(g_state.vocab, tok, big.data(), static_cast<int32_t>(big.size()), 0, false);
    if (n < 0) return std::string();
    big.resize(static_cast<size_t>(n));
    return big;
}

llama_sampler *make_sampler(const GenParams &p) {
    auto sp = llama_sampler_chain_default_params();
    sp.no_perf = true;
    llama_sampler *chain = llama_sampler_chain_init(sp);
    if (p.repeat_penalty > 0.0f && p.repeat_penalty != 1.0f && p.repeat_last_n != 0) {
        llama_sampler_chain_add(chain,
                                llama_sampler_init_penalties(llama_vocab_n_tokens(g_state.vocab),
                                                             p.repeat_last_n, p.repeat_penalty, 0.0f, 0.0f));
    }
    if (p.temperature <= 0.0f) {
        llama_sampler_chain_add(chain, llama_sampler_init_greedy());
        return chain;
    }
    if (p.top_k > 0) llama_sampler_chain_add(chain, llama_sampler_init_top_k(p.top_k));
    if (p.top_p > 0.0f && p.top_p < 1.0f) llama_sampler_chain_add(chain, llama_sampler_init_top_p(p.top_p, 1));
    if (p.min_p > 0.0f) llama_sampler_chain_add(chain, llama_sampler_init_min_p(p.min_p, 1));
    llama_sampler_chain_add(chain, llama_sampler_init_temp(p.temperature));
    llama_sampler_chain_add(chain, llama_sampler_init_dist(p.seed));
    return chain;
}

// Drops the KV cache from position `keep` onwards. Falls back to a full clear when the
// memory type cannot remove a partial range (e.g. sliding-window / recurrent caches).
size_t trim_cache(size_t keep) {
    llama_memory_t mem = llama_get_memory(g_state.ctx);
    if (keep >= g_state.cached.size()) return keep;
    if (keep > 0 && llama_memory_seq_rm(mem, 0, static_cast<llama_pos>(keep), -1)) {
        g_state.cached.resize(keep);
        return keep;
    }
    llama_memory_clear(mem, true);
    g_state.cached.clear();
    return 0;
}

}  // namespace

size_t complete_utf8_prefix(const std::string &s) {
    const size_t n = s.size();
    if (n == 0) return 0;
    // Walk back over at most 3 continuation bytes to find the last lead byte.
    size_t i = n;
    size_t back = 0;
    while (i > 0 && back < 4) {
        const auto c = static_cast<unsigned char>(s[i - 1]);
        if ((c & 0xC0) != 0x80) break;  // not a continuation byte
        --i;
        ++back;
    }
    if (i == 0) return n;  // only continuation bytes (invalid); flush as-is
    const auto lead = static_cast<unsigned char>(s[i - 1]);
    size_t need = 1;
    if ((lead & 0x80) == 0x00) need = 1;
    else if ((lead & 0xE0) == 0xC0) need = 2;
    else if ((lead & 0xF0) == 0xE0) need = 3;
    else if ((lead & 0xF8) == 0xF0) need = 4;
    else return n;  // invalid lead byte; let the decoder replace it
    const size_t have = back + 1;
    return have >= need ? n : (i - 1);
}

int32_t init_backends(const std::string &backend_dir) {
    llama_log_set(log_callback, nullptr);
    if (!g_backends_ready.exchange(true)) {
        if (!backend_dir.empty()) {
            ggml_backend_load_all_from_path(backend_dir.c_str());
        }
        llama_backend_init();
    }
    return static_cast<int32_t>(ggml_backend_dev_count());
}

int32_t load_model(const std::string &path, int32_t n_ctx, int32_t n_threads) {
    std::lock_guard<std::mutex> lock(g_mutex);
    free_locked();
    if (ggml_backend_dev_count() == 0) return LOAD_ERR_NO_BACKEND;

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = 0;  // CPU only on phones
    g_state.model = llama_model_load_from_file(path.c_str(), mp);
    if (g_state.model == nullptr) {
        free_locked();
        return LOAD_ERR_MODEL;
    }
    g_state.vocab = llama_model_get_vocab(g_state.model);

    const int32_t train_ctx = llama_model_n_ctx_train(g_state.model);
    int32_t ctx_size = n_ctx > 0 ? n_ctx : 4096;
    if (train_ctx > 0) ctx_size = std::min(ctx_size, train_ctx);
    ctx_size = std::max(ctx_size, 512);

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = static_cast<uint32_t>(ctx_size);
    cp.n_batch = static_cast<uint32_t>(g_state.n_batch);
    cp.n_ubatch = static_cast<uint32_t>(g_state.n_batch);
    cp.n_seq_max = 1;
    const int32_t threads = std::max(1, n_threads);
    cp.n_threads = threads;
    cp.n_threads_batch = threads;
    cp.abort_callback = abort_callback;
    cp.abort_callback_data = nullptr;
    cp.no_perf = true;
    g_state.ctx = llama_init_from_model(g_state.model, cp);
    if (g_state.ctx == nullptr) {
        free_locked();
        return LOAD_ERR_CONTEXT;
    }
    g_state.n_ctx = static_cast<int32_t>(llama_n_ctx(g_state.ctx));

    const char *tmpl = llama_model_chat_template(g_state.model, nullptr);
    if (tmpl != nullptr && tmpl[0] != '\0') {
        // Probe the template once; unsupported templates fall back to ChatML.
        llama_chat_message probe[2] = {{"system", "s"}, {"user", "u"}};
        std::vector<llama_chat_message> v(probe, probe + 2);
        std::string out;
        if (apply_template(tmpl, v, out)) {
            g_state.tmpl = tmpl;
            g_state.tmpl_name = "gguf";
        }
    }
    return LOAD_OK;
}

void unload_model() {
    std::lock_guard<std::mutex> lock(g_mutex);
    free_locked();
}

bool is_loaded() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_state.ctx != nullptr;
}

void cancel() { g_cancel.store(true, std::memory_order_relaxed); }

std::string model_description() {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_state.model == nullptr) return std::string();
    char buf[256];
    const int32_t n = llama_model_desc(g_state.model, buf, sizeof(buf));
    return n > 0 ? std::string(buf, static_cast<size_t>(std::min<int32_t>(n, sizeof(buf) - 1))) : std::string();
}

int32_t context_size() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_state.n_ctx;
}

std::string chat_template_name() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_state.tmpl_name;
}

int32_t generate(const std::vector<ChatMessage> &messages, const GenParams &params, const TokenSink &sink,
                 GenStats *stats) {
    std::unique_lock<std::mutex> lock(g_mutex, std::try_to_lock);
    if (!lock.owns_lock()) return GEN_ERR_BUSY;
    if (g_state.ctx == nullptr) return GEN_ERR_NOT_LOADED;
    g_cancel.store(false, std::memory_order_relaxed);

    GenStats local;
    GenStats &st = stats != nullptr ? *stats : local;
    st = GenStats();

    // 1) Format with the model's chat template.
    std::vector<llama_chat_message> msgs;
    msgs.reserve(messages.size());
    for (const auto &m : messages) msgs.push_back({m.role.c_str(), m.content.c_str()});
    std::string prompt;
    const char *tmpl = g_state.tmpl.empty() ? "chatml" : g_state.tmpl.c_str();
    if (!apply_template(tmpl, msgs, prompt)) {
        if (!apply_template("chatml", msgs, prompt)) return GEN_ERR_TEMPLATE;
    }

    // 2) Tokenize and check the window.
    std::vector<llama_token> tokens;
    if (!tokenize(prompt, tokens) || tokens.empty()) return GEN_ERR_TOKENIZE;
    st.prompt_tokens = static_cast<int32_t>(tokens.size());
    if (static_cast<int32_t>(tokens.size()) + 8 >= g_state.n_ctx) return GEN_ERR_PROMPT_TOO_LONG;

    // 3) Reuse the longest common prefix that is already in the KV cache.
    size_t common = 0;
    while (common < tokens.size() && common < g_state.cached.size() && tokens[common] == g_state.cached[common]) {
        ++common;
    }
    if (common == tokens.size()) common = tokens.size() - 1;  // must decode >= 1 token for fresh logits
    common = trim_cache(common);
    st.reused_tokens = static_cast<int32_t>(common);

    // 4) Prefill in batches.
    const auto t_prefill = std::chrono::steady_clock::now();
    for (size_t i = common; i < tokens.size(); i += static_cast<size_t>(g_state.n_batch)) {
        const size_t n = std::min(static_cast<size_t>(g_state.n_batch), tokens.size() - i);
        llama_batch batch = llama_batch_get_one(tokens.data() + i, static_cast<int32_t>(n));
        const int32_t rc = llama_decode(g_state.ctx, batch);
        if (rc != 0) {
            llama_memory_clear(llama_get_memory(g_state.ctx), true);
            g_state.cached.clear();
            return (rc == 2 || g_cancel.load()) ? GEN_CANCELLED : GEN_ERR_DECODE;
        }
        g_state.cached.insert(g_state.cached.end(), tokens.begin() + static_cast<long>(i),
                              tokens.begin() + static_cast<long>(i + n));
    }
    st.prefill_ms = ms_since(t_prefill);

    // 5) Sample token by token, emitting only complete UTF-8 sequences.
    llama_sampler *smpl = make_sampler(params);
    std::string pending;
    int32_t status = GEN_MAX_TOKENS;
    const auto t_gen = std::chrono::steady_clock::now();
    const int32_t max_tokens = params.max_tokens > 0 ? params.max_tokens : 512;
    for (int32_t i = 0; i < max_tokens; ++i) {
        if (g_cancel.load(std::memory_order_relaxed)) {
            status = GEN_CANCELLED;
            break;
        }
        if (static_cast<int32_t>(g_state.cached.size()) >= g_state.n_ctx - 1) {
            status = GEN_CONTEXT_FULL;
            break;
        }
        llama_token tok = llama_sampler_sample(smpl, g_state.ctx, -1);  // also accepts the token
        if (llama_vocab_is_eog(g_state.vocab, tok)) {
            status = GEN_DONE;
            break;
        }
        pending += token_piece(tok);
        const size_t ready = complete_utf8_prefix(pending);
        if (ready > 0) {
            const std::string chunk = pending.substr(0, ready);
            pending.erase(0, ready);
            if (!sink(chunk)) {
                status = GEN_CANCELLED;
                break;
            }
        }
        st.generated_tokens++;
        llama_batch batch = llama_batch_get_one(&tok, 1);
        const int32_t rc = llama_decode(g_state.ctx, batch);
        if (rc != 0) {
            llama_memory_clear(llama_get_memory(g_state.ctx), true);
            g_state.cached.clear();
            status = (rc == 2 || g_cancel.load()) ? GEN_CANCELLED : GEN_ERR_DECODE;
            break;
        }
        g_state.cached.push_back(tok);
    }
    if (!pending.empty() && status != GEN_ERR_DECODE) sink(pending);
    st.generate_ms = ms_since(t_gen);
    llama_sampler_free(smpl);
    g_cancel.store(false, std::memory_order_relaxed);
    return status;
}

}  // namespace kiro

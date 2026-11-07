// Host-side test of the Kiro C++ engine (the code behind libkiro_llm.so) against a real GGUF.
// Not part of CI (needs a model file). See README.md in this folder.
#include <cassert>
#include <chrono>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#include "kiro_engine.h"

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s model.gguf\n", argv[0]);
        return 2;
    }
    // UTF-8 completeness (Persian letters are 2 bytes, emoji 4).
    const std::string fa = "سلام";
    assert(kiro::complete_utf8_prefix(fa) == fa.size());
    assert(kiro::complete_utf8_prefix(fa.substr(0, 7)) == 6);
    const std::string emoji = "a\xF0\x9F\x98\x80";
    assert(kiro::complete_utf8_prefix(emoji.substr(0, 4)) == 1);
    assert(kiro::complete_utf8_prefix(emoji) == 5);

    std::printf("devices=%d\n", kiro::init_backends(""));
    int rc = kiro::load_model(argv[1], 2048, 2);
    std::printf("load=%d desc=%s ctx=%d template=%s\n", rc, kiro::model_description().c_str(), kiro::context_size(),
                kiro::chat_template_name().c_str());
    if (rc != 0) return 1;

    std::vector<kiro::ChatMessage> m = {{"system", "You are a helpful assistant. Reply in Persian."},
                                        {"user", "یک جمله دربارهٔ اینستاگرام بنویس."}};
    kiro::GenParams p;
    p.max_tokens = 60;
    kiro::GenStats st;
    std::string out;
    int s = kiro::generate(m, p, [&](const std::string &c) { out += c; std::fputs(c.c_str(), stdout); std::fflush(stdout); return true; }, &st);
    std::printf("\nstatus=%d prompt=%d reused=%d generated=%d\n", s, st.prompt_tokens, st.reused_tokens, st.generated_tokens);
    assert(s == kiro::GEN_DONE || s == kiro::GEN_MAX_TOKENS);

    // Second turn reuses the KV-cache prefix.
    m.push_back({"assistant", out});
    m.push_back({"user", "Now one short sentence in English."});
    s = kiro::generate(m, p, [&](const std::string &) { return true; }, &st);
    std::printf("turn2 status=%d reused=%d\n", s, st.reused_tokens);
    assert(st.reused_tokens > 0);

    // Cancel from another thread.
    std::vector<kiro::ChatMessage> essay = {{"user", "Write a very long essay about the history of photography."}};
    p.max_tokens = 600;
    std::thread t([] { std::this_thread::sleep_for(std::chrono::milliseconds(2000)); kiro::cancel(); });
    s = kiro::generate(essay, p, [](const std::string &) { return true; }, &st);
    t.join();
    std::printf("cancel status=%d generated=%d\n", s, st.generated_tokens);

    // Callback stop.
    s = kiro::generate(essay, p, [](const std::string &) { return false; }, &st);
    assert(s == kiro::GEN_CANCELLED);

    // Prompt longer than the context.
    std::string big;
    for (int i = 0; i < 3000; i++) big += "word ";
    s = kiro::generate({{"user", big}}, p, [](const std::string &) { return true; }, &st);
    assert(s == kiro::GEN_ERR_PROMPT_TOO_LONG);

    kiro::unload_model();
    assert(!kiro::is_loaded());
    assert(kiro::generate(m, p, [](const std::string &) { return true; }, nullptr) == kiro::GEN_ERR_NOT_LOADED);
    std::printf("ALL OK\n");
    return 0;
}

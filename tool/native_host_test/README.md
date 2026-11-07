# تست موتور C++ روی کامپیوتر

این تست، همان کد `kiro_engine.cpp` را که داخل `libkiro_llm.so` است، با llama.cpp همان تگ و یک مدل GGUF واقعی روی کامپیوتر اجرا می‌کند (تولید جریانی فارسی، استفادهٔ دوباره از کش، توقف، خطای پرامپت طولانی). به‌دلیل نیاز به فایل مدل، در CI اجرا نمی‌شود.

```bash
git clone --depth 1 -b b12191 https://github.com/ggml-org/llama.cpp.git /tmp/llama.cpp
cmake -S tool/native_host_test -B build/host_test -DLLAMA_SRC=/tmp/llama.cpp -DCMAKE_BUILD_TYPE=Release
cmake --build build/host_test -j
# مدل کوچک برای تست:
curl -L -o /tmp/qwen05.gguf https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
build/host_test/kiro_engine_test /tmp/qwen05.gguf
```

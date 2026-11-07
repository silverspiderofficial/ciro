// JNI bridge for com.silverspider.kiro.llm.LlamaNative. Runs inside the ":ai" process only.
#include <jni.h>

#include <string>
#include <vector>

#include "kiro_engine.h"

namespace {

std::string to_std(JNIEnv *env, jstring s) {
    if (s == nullptr) return std::string();
    const jsize len = env->GetStringUTFLength(s);
    const char *chars = env->GetStringUTFChars(s, nullptr);
    std::string out(chars, static_cast<size_t>(len));
    env->ReleaseStringUTFChars(s, chars);
    return out;
}

// Java strings may contain characters outside the BMP; GetStringUTFChars returns modified
// UTF-8 for those, so convert through a byte[] produced by the Kotlin side instead.
std::string bytes_to_std(JNIEnv *env, jbyteArray arr) {
    if (arr == nullptr) return std::string();
    const jsize len = env->GetArrayLength(arr);
    std::string out(static_cast<size_t>(len), '\0');
    if (len > 0) env->GetByteArrayRegion(arr, 0, len, reinterpret_cast<jbyte *>(out.data()));
    return out;
}

}  // namespace

extern "C" {

JNIEXPORT jint JNICALL Java_com_silverspider_kiro_llm_LlamaNative_nativeInit(JNIEnv *env, jobject /*thiz*/,
                                                                             jstring backend_dir) {
    return kiro::init_backends(to_std(env, backend_dir));
}

JNIEXPORT jint JNICALL Java_com_silverspider_kiro_llm_LlamaNative_nativeLoad(JNIEnv *env, jobject /*thiz*/,
                                                                             jstring path, jint n_ctx,
                                                                             jint n_threads) {
    return kiro::load_model(to_std(env, path), n_ctx, n_threads);
}

JNIEXPORT void JNICALL Java_com_silverspider_kiro_llm_LlamaNative_nativeUnload(JNIEnv * /*env*/,
                                                                               jobject /*thiz*/) {
    kiro::unload_model();
}

JNIEXPORT void JNICALL Java_com_silverspider_kiro_llm_LlamaNative_nativeCancel(JNIEnv * /*env*/,
                                                                               jobject /*thiz*/) {
    kiro::cancel();
}

JNIEXPORT jstring JNICALL Java_com_silverspider_kiro_llm_LlamaNative_nativeDescription(JNIEnv *env,
                                                                                      jobject /*thiz*/) {
    const std::string d = kiro::model_description() + "|" + std::to_string(kiro::context_size()) + "|" +
                          kiro::chat_template_name();
    return env->NewStringUTF(d.c_str());
}

// roles/contents are parallel arrays of UTF-8 byte arrays. stats receives
// [prompt_tokens, reused_tokens, generated_tokens, prefill_ms, generate_ms].
JNIEXPORT jint JNICALL Java_com_silverspider_kiro_llm_LlamaNative_nativeGenerate(
    JNIEnv *env, jobject /*thiz*/, jobjectArray roles, jobjectArray contents, jint max_tokens, jfloat temperature,
    jfloat top_p, jint top_k, jfloat repeat_penalty, jobject callback, jdoubleArray stats_out) {
    const jsize n = env->GetArrayLength(roles);
    if (n != env->GetArrayLength(contents)) return kiro::GEN_ERR_TEMPLATE;

    std::vector<kiro::ChatMessage> messages;
    messages.reserve(static_cast<size_t>(n));
    for (jsize i = 0; i < n; ++i) {
        auto r = static_cast<jbyteArray>(env->GetObjectArrayElement(roles, i));
        auto c = static_cast<jbyteArray>(env->GetObjectArrayElement(contents, i));
        messages.push_back({bytes_to_std(env, r), bytes_to_std(env, c)});
        env->DeleteLocalRef(r);
        env->DeleteLocalRef(c);
    }

    kiro::GenParams params;
    params.max_tokens = max_tokens;
    params.temperature = temperature;
    params.top_p = top_p;
    params.top_k = top_k;
    params.repeat_penalty = repeat_penalty;

    jclass cb_class = env->GetObjectClass(callback);
    jmethodID on_token = env->GetMethodID(cb_class, "onToken", "([B)Z");
    env->DeleteLocalRef(cb_class);
    if (on_token == nullptr) return kiro::GEN_ERR_TEMPLATE;

    kiro::TokenSink sink = [env, callback, on_token](const std::string &chunk) -> bool {
        jbyteArray arr = env->NewByteArray(static_cast<jsize>(chunk.size()));
        if (arr == nullptr) return false;
        env->SetByteArrayRegion(arr, 0, static_cast<jsize>(chunk.size()),
                                reinterpret_cast<const jbyte *>(chunk.data()));
        const jboolean keep_going = env->CallBooleanMethod(callback, on_token, arr);
        env->DeleteLocalRef(arr);
        if (env->ExceptionCheck()) {
            env->ExceptionClear();
            return false;
        }
        return keep_going == JNI_TRUE;
    };

    kiro::GenStats stats;
    const int32_t status = kiro::generate(messages, params, sink, &stats);
    if (stats_out != nullptr && env->GetArrayLength(stats_out) >= 5) {
        const jdouble values[5] = {static_cast<jdouble>(stats.prompt_tokens),
                                   static_cast<jdouble>(stats.reused_tokens),
                                   static_cast<jdouble>(stats.generated_tokens), stats.prefill_ms,
                                   stats.generate_ms};
        env->SetDoubleArrayRegion(stats_out, 0, 5, values);
    }
    return status;
}

}  // extern "C"

// JNI bridge for com.silverspider.kiro.image.SdNative (Android, ":ai" process only).
#include <jni.h>

#include <string>

#include "kiro_sd.h"

namespace {

JavaVM* g_vm = nullptr;

struct ProgressCtx {
    jobject callback;   // global ref
    jmethodID on_step;
};

std::string to_string(JNIEnv* env, jstring s) {
    if (!s) return {};
    const char* c = env->GetStringUTFChars(s, nullptr);
    std::string out = c ? c : "";
    if (c) env->ReleaseStringUTFChars(s, c);
    return out;
}

void on_progress(int step, int steps, void* user) {
    auto* p = static_cast<ProgressCtx*>(user);
    if (!p || !p->callback || !g_vm) return;
    JNIEnv* env = nullptr;
    bool attached = false;
    if (g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
        if (g_vm->AttachCurrentThread(&env, nullptr) != JNI_OK) return;
        attached = true;
    }
    env->CallVoidMethod(p->callback, p->on_step, (jint)step, (jint)steps);
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (attached) g_vm->DetachCurrentThread();
}

}  // namespace

extern "C" {

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
    g_vm = vm;
    return JNI_VERSION_1_6;
}

JNIEXPORT jlong JNICALL Java_com_silverspider_kiro_image_SdNative_nativeLoad(
    JNIEnv* env, jclass, jstring model, jstring taesd, jint threads) {
    const std::string m = to_string(env, model);
    const std::string t = to_string(env, taesd);
    return reinterpret_cast<jlong>(kiro_sd_load(m.c_str(), t.c_str(), threads));
}

JNIEXPORT jint JNICALL Java_com_silverspider_kiro_image_SdNative_nativeGenerate(
    JNIEnv* env, jclass, jlong handle, jstring prompt, jstring negative, jint width, jint height,
    jint steps, jfloat cfg, jlong seed, jstring outPath, jobject callback, jlongArray seedOut) {
    auto* ctx = reinterpret_cast<kiro_sd*>(handle);
    if (!ctx) return KIRO_SD_ERR_ARGS;
    const std::string p = to_string(env, prompt);
    const std::string n = to_string(env, negative);
    const std::string o = to_string(env, outPath);

    ProgressCtx pc{nullptr, nullptr};
    if (callback) {
        jclass cls = env->GetObjectClass(callback);
        pc.on_step = env->GetMethodID(cls, "onStep", "(II)V");
        env->DeleteLocalRef(cls);
        if (pc.on_step) pc.callback = env->NewGlobalRef(callback);
        if (env->ExceptionCheck()) env->ExceptionClear();
    }
    int64_t used_seed = seed;
    const int rc = kiro_sd_txt2img(ctx, p.c_str(), n.c_str(), width, height, steps, cfg, seed, o.c_str(),
                                   pc.callback ? on_progress : nullptr, &pc, &used_seed);
    if (pc.callback) env->DeleteGlobalRef(pc.callback);
    if (seedOut && env->GetArrayLength(seedOut) > 0) {
        jlong v = (jlong)used_seed;
        env->SetLongArrayRegion(seedOut, 0, 1, &v);
    }
    return rc;
}

JNIEXPORT void JNICALL Java_com_silverspider_kiro_image_SdNative_nativeCancel(JNIEnv*, jclass, jlong handle) {
    kiro_sd_cancel(reinterpret_cast<kiro_sd*>(handle));
}

JNIEXPORT jstring JNICALL Java_com_silverspider_kiro_image_SdNative_nativeModelName(JNIEnv* env, jclass, jlong handle) {
    return env->NewStringUTF(kiro_sd_model_name(reinterpret_cast<kiro_sd*>(handle)));
}

JNIEXPORT jstring JNICALL Java_com_silverspider_kiro_image_SdNative_nativeSystemInfo(JNIEnv* env, jclass) {
    return env->NewStringUTF(kiro_sd_system_info());
}

JNIEXPORT void JNICALL Java_com_silverspider_kiro_image_SdNative_nativeFree(JNIEnv*, jclass, jlong handle) {
    kiro_sd_free(reinterpret_cast<kiro_sd*>(handle));
}

}  // extern "C"

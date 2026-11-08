package com.silverspider.kiro.image

/** Receives sampling progress from native code. Called from JNI by name: keep onStep(II)V. */
fun interface SdProgress {
    fun onStep(step: Int, steps: Int)
}

/**
 * JNI surface of libkiro_sd.so (stable-diffusion.cpp). Only used inside the ":ai" process.
 * Status codes mirror native/kiro_sd/kiro_sd.h.
 */
object SdNative {
    const val OK = 0
    const val ERR_ARGS = -1
    const val ERR_GENERATE = -2
    const val ERR_CANCELLED = -3
    const val ERR_WRITE = -4

    @Volatile
    private var libraryLoaded = false

    /** Loads libkiro_sd.so once. Throws UnsatisfiedLinkError when it is missing. */
    @Synchronized
    fun ensureLibrary() {
        if (!libraryLoaded) {
            System.loadLibrary("kiro_sd")
            libraryLoaded = true
        }
    }

    @JvmStatic external fun nativeLoad(model: String, taesd: String, threads: Int): Long
    @JvmStatic external fun nativeGenerate(
        handle: Long,
        prompt: String,
        negative: String,
        width: Int,
        height: Int,
        steps: Int,
        cfg: Float,
        seed: Long,
        outPath: String,
        callback: SdProgress?,
        seedOut: LongArray,
    ): Int
    @JvmStatic external fun nativeCancel(handle: Long)
    @JvmStatic external fun nativeModelName(handle: Long): String
    @JvmStatic external fun nativeSystemInfo(): String
    @JvmStatic external fun nativeFree(handle: Long)
}

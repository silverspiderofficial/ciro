package com.silverspider.kiro.llm

/** Receives complete UTF-8 chunks from native generation. Return false to stop. Called from JNI. */
fun interface TokenCallback {
    fun onToken(bytes: ByteArray): Boolean
}

/**
 * JNI surface of libkiro_llm.so (llama.cpp). Only ever used inside the ":ai" process.
 * Status codes mirror kiro_engine.h.
 */
object LlamaNative {
    const val LOAD_OK = 0
    const val LOAD_ERR_MODEL = 1
    const val LOAD_ERR_CONTEXT = 2
    const val LOAD_ERR_NO_BACKEND = 3

    const val GEN_DONE = 0
    const val GEN_MAX_TOKENS = 1
    const val GEN_CANCELLED = 2
    const val GEN_CONTEXT_FULL = 3
    const val GEN_ERR_NOT_LOADED = -1
    const val GEN_ERR_TEMPLATE = -2
    const val GEN_ERR_TOKENIZE = -3
    const val GEN_ERR_PROMPT_TOO_LONG = -4
    const val GEN_ERR_DECODE = -5
    const val GEN_ERR_BUSY = -6

    @Volatile
    private var libraryLoaded = false

    @Synchronized
    fun ensureLibrary() {
        if (!libraryLoaded) {
            System.loadLibrary("kiro_llm")
            libraryLoaded = true
        }
    }

    @JvmStatic external fun nativeInit(backendDir: String): Int
    @JvmStatic external fun nativeLoad(path: String, nCtx: Int, nThreads: Int): Int
    @JvmStatic external fun nativeUnload()
    @JvmStatic external fun nativeCancel()
    @JvmStatic external fun nativeDescription(): String
    @JvmStatic external fun nativeGenerate(
        roles: Array<ByteArray>,
        contents: Array<ByteArray>,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        repeatPenalty: Float,
        callback: TokenCallback,
        statsOut: DoubleArray,
    ): Int
}

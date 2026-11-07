package com.silverspider.kiro.llm

/** Messenger protocol between the UI process and the ":ai" LlmService process. */
object LlmIpc {
    // client -> service
    const val MSG_LOAD = 1
    const val MSG_UNLOAD = 2
    const val MSG_GENERATE = 3
    const val MSG_CANCEL = 4
    const val MSG_STATUS = 5

    // service -> client
    const val MSG_LOADED = 101
    const val MSG_UNLOADED = 102
    const val MSG_TOKEN = 103
    const val MSG_DONE = 104
    const val MSG_ERROR = 105
    const val MSG_STATUS_REPLY = 106

    const val KEY_PATH = "path"
    const val KEY_N_CTX = "nCtx"
    const val KEY_THREADS = "threads"
    const val KEY_FORCE = "force"
    const val KEY_ROLES = "roles"
    const val KEY_CONTENTS = "contents"
    const val KEY_MAX_TOKENS = "maxTokens"
    const val KEY_TEMPERATURE = "temperature"
    const val KEY_TOP_P = "topP"
    const val KEY_TOP_K = "topK"
    const val KEY_REPEAT_PENALTY = "repeatPenalty"
    const val KEY_TEXT = "text"
    const val KEY_STATUS = "status"
    const val KEY_CODE = "code"
    const val KEY_MESSAGE = "message"
    const val KEY_DESCRIPTION = "description"
    const val KEY_STATS = "stats"
    const val KEY_AVAIL = "availBytes"
    const val KEY_NEED = "needBytes"
    const val KEY_LOADED = "loaded"
}

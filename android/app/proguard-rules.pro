# ---- JNI (libkiro_llm.so) ----
# Native method names are bound by symbol name (Java_com_silverspider_kiro_llm_LlamaNative_*).
-keep class com.silverspider.kiro.llm.LlamaNative {
    native <methods>;
}
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
# onToken([B)Z is looked up from C++ with GetMethodID on the callback's runtime class.
-keep interface com.silverspider.kiro.llm.TokenCallback { *; }
-keep class * implements com.silverspider.kiro.llm.TokenCallback {
    public boolean onToken(byte[]);
}

# ---- Flutter ----
# The embedding references optional Play Core deferred-components classes; Kiro has no
# Google Play Services dependency, so silence the missing-class warnings only.
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**

# ---- Hardening ----
# Strip android.util.Log debug/verbose/info calls from release bytecode.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
}
-renamesourcefileattribute ''

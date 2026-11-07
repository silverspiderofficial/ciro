package com.silverspider.kiro.security

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Debug
import com.silverspider.kiro.BuildConfig
import java.io.File
import java.security.MessageDigest

/**
 * Lightweight, dependency-free integrity checks. None of these is unbeatable; together they
 * raise the cost of tampering. When anything trips, the app warns and locks sensitive features
 * (the optional cloud API key) instead of crashing.
 */
object SecurityChecks {

    private val SU_PATHS = listOf(
        "/system/bin/su", "/system/xbin/su", "/sbin/su", "/system/su", "/system/bin/.ext/su",
        "/system/usr/we-need-root/su", "/vendor/bin/su", "/data/local/su", "/data/local/bin/su",
        "/data/local/xbin/su", "/su/bin/su", "/system/app/Superuser.apk", "/system/xbin/daemonsu",
        "/data/adb/magisk", "/sbin/.magisk", "/data/adb/ksu", "/data/adb/ap",
    )

    private val ROOT_PACKAGES = listOf(
        "com.topjohnwu.magisk", "io.github.vvb2060.magisk", "eu.chainfire.supersu",
        "com.noshufou.android.su", "com.koushikdutta.superuser", "me.weishu.kernelsu",
        "me.bmax.apatch", "com.kingroot.kinguser",
    )

    private val HOOK_MARKERS = listOf("frida", "xposed", "lsposed", "substrate", "zygisk")

    fun check(context: Context): Map<String, Any?> {
        val rooted = isRooted(context)
        val debugger = isDebuggerAttached()
        val debuggable = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val hooked = hasHookFramework()
        val emulator = isEmulator()
        val certs = signingCertSha256s(context)
        val expected = BuildConfig.EXPECTED_CERT_SHA256.replace(":", "").trim().uppercase()
        val signature = when {
            expected.isEmpty() -> "unchecked"
            certs.contains(expected) -> "match"
            else -> "mismatch"
        }
        // A debug build is debuggable by design; only flag that in release builds.
        val unexpectedDebuggable = debuggable && !BuildConfig.DEBUG
        val compromised = rooted || debugger || hooked || signature == "mismatch" || unexpectedDebuggable
        return mapOf(
            "rooted" to rooted,
            "debugger" to debugger,
            "debuggable" to unexpectedDebuggable,
            "hooked" to hooked,
            "emulator" to emulator,
            "signature" to signature,
            "compromised" to compromised,
        )
    }

    private fun isRooted(context: Context): Boolean {
        if (SU_PATHS.any { File(it).exists() }) return true
        if (Build.TAGS?.contains("test-keys") == true) return true
        val pm = context.packageManager
        for (pkg in ROOT_PACKAGES) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    pm.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
                } else {
                    @Suppress("DEPRECATION")
                    pm.getPackageInfo(pkg, 0)
                }
                return true
            } catch (e: PackageManager.NameNotFoundException) {
                // not installed
            }
        }
        return System.getenv("PATH")?.split(':')?.any { File(it, "su").exists() } == true
    }

    private fun isDebuggerAttached(): Boolean {
        if (Debug.isDebuggerConnected() || Debug.waitingForDebugger()) return true
        return try {
            File("/proc/self/status").useLines { lines ->
                lines.firstOrNull { it.startsWith("TracerPid:") }
                    ?.substringAfter(':')?.trim()?.toIntOrNull()?.let { it != 0 } ?: false
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun hasHookFramework(): Boolean {
        val inMaps = try {
            File("/proc/self/maps").useLines { lines ->
                lines.any { line -> val l = line.lowercase(); HOOK_MARKERS.any { l.contains(it) } }
            }
        } catch (e: Exception) {
            false
        }
        if (inMaps) return true
        return try {
            Class.forName("de.robv.android.xposed.XposedBridge")
            true
        } catch (e: ClassNotFoundException) {
            false
        }
    }

    private fun isEmulator(): Boolean {
        val fp = Build.FINGERPRINT.orEmpty()
        return fp.startsWith("generic") || fp.contains("emulator") || fp.contains("sdk_gphone") ||
            Build.MODEL.contains("Emulator") || Build.MODEL.contains("Android SDK built for") ||
            Build.HARDWARE.contains("goldfish") || Build.HARDWARE.contains("ranchu") ||
            Build.PRODUCT.contains("sdk") || Build.MANUFACTURER.contains("Genymotion")
    }

    /** SHA-256 of each APK signing certificate (incl. rotation history), uppercase hex. */
    @SuppressLint("PackageManagerGetSignatures")
    fun signingCertSha256s(context: Context): List<String> = try {
        val pm = context.packageManager
        val name = context.packageName
        val certs: List<ByteArray> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(name, PackageManager.PackageInfoFlags.of(PackageManager.GET_SIGNING_CERTIFICATES.toLong()))
            } else {
                pm.getPackageInfo(name, PackageManager.GET_SIGNING_CERTIFICATES)
            }
            val signing = info.signingInfo
            when {
                signing == null -> emptyList()
                signing.hasMultipleSigners() -> signing.apkContentsSigners.map { it.toByteArray() }
                else -> signing.signingCertificateHistory.map { it.toByteArray() }
            }
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(name, PackageManager.GET_SIGNATURES).signatures?.map { it.toByteArray() } ?: emptyList()
        }
        certs.map { bytes ->
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02X".format(it) }
        }
    } catch (e: Exception) {
        emptyList()
    }
}
